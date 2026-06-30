#!/usr/bin/env bash
set -euo pipefail

# Visual separator for log output.
nl=$'\n-------------------------------------\n'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# WireGuard interface name created by boringtun.
WG_IFACE="${WG_IFACE:-wg0}"

# IPv4 address assigned to the WireGuard interface inside this container.
#
# IMPORTANT:
# This must be a host address, not the subnet/network address.
#
# Good:
#   10.1.10.1/24
#
# Bad:
#   10.1.10.0/24
#
# Kept as IP_WG_ENV for compatibility with existing compose/environment.
WG_ADDR="${IP_WG_ENV:-10.1.10.1/24}"

# VPN client subnet used for iptables matching and NAT.
#
# This is the subnet clients receive addresses from. It should match the
# Address/AllowedIPs design in the WireGuard config.
WG_SUBNET="${WG_SUBNET:-10.1.10.0/24}"

# iptables command to use.
#
# Alpine may provide both nft-backed iptables and legacy iptables. Since the
# original setup was using iptables-legacy, keep that explicit and consistent.
IPT="${IPT:-iptables-legacy}"

# Path to the boringtun userspace WireGuard binary.
BORINGTUN_BIN="${BORINGTUN_BIN:-/data/boringtun}"

# WireGuard config file mounted into the container.
WG_CONFIG="${WG_CONFIG:-/config/wireguard.conf}"

# Optional custom iptables script for service-specific DNAT rules, such as
# forwarding VPN HTTPS traffic to an nginx container.
#
# Other services can be added on an as-needed basis.
#
CUSTOM_IPTABLES_SCRIPT="${CUSTOM_IPTABLES_SCRIPT:-/config/iptables.sh}"

# MTU for the WireGuard interface. 1420 is the common WireGuard default for
# ethernet networks with 1500 MTU.
WG_MTU="${WG_MTU:-1420}"

# ---------------------------------------------------------------------------
# Start boringtun and create the WireGuard interface
# ---------------------------------------------------------------------------

if [[ ! -f "$BORINGTUN_BIN" ]]; then
    printf "ERROR: WireGuard userspace binary not found at %s\n" "$BORINGTUN_BIN" >&2
    exit 1
fi

printf "Starting WireGuard userspace using boringtun...\n"

# Ensure /dev/net/tun exists. Some container runtimes expose this device via
# compose/docker flags, but creating the node here makes the script more robust.
mkdir -p /dev/net

if [[ ! -e /dev/net/tun ]]; then
    mknod /dev/net/tun c 10 200
fi

# Start boringtun in foreground mode, but background the process from this
# script so we can continue configuring the interface.
#
# --disable-drop-privileges is a bare flag in the current boringtun CLI.
#
# nice -n -10 requires SYS_NICE. If the container lacks SYS_NICE, this may fail.
# This is intended to be an incremental performance improvement for the service.
nice -n -10 "$BORINGTUN_BIN" --disable-drop-privileges -f "$WG_IFACE" &
wireguard_pid=$!

# Wait for boringtun to create wg0. This avoids racing into ip/wg commands
# before the interface exists.
for _ in {1..20}; do
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        break
    fi

    if ! kill -0 "$wireguard_pid" 2>/dev/null; then
        printf "ERROR: boringtun exited before creating %s\n" "$WG_IFACE" >&2
        exit 1
    fi

    printf "Waiting for %s...\n" "$WG_IFACE"
    sleep 1
done

if ! ip link show "$WG_IFACE" >/dev/null 2>&1; then
    printf "ERROR: %s was not created\n" "$WG_IFACE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Discover container egress interface
# ---------------------------------------------------------------------------

# Extract the default outbound interface inside the container, usually eth0.
#
# Example route:
#   default via 172.20.0.1 dev eth0
#
# This reads the fifth field from that route.
read -r _ _ _ _ egress_iface _ < <(ip route show default)

if [[ -z "${egress_iface:-}" ]]; then
    printf "ERROR: could not determine default egress interface\n" >&2
    exit 1
fi

printf "Default egress interface: %s\n" "$egress_iface"

# ---------------------------------------------------------------------------
# Configure WireGuard interface address and MTU
# ---------------------------------------------------------------------------

printf "Setting WireGuard IPv4 address: %s on %s...\n" "$WG_ADDR" "$WG_IFACE"

# Avoid failing if the address already exists from a previous run/restart.
ip addr add "$WG_ADDR" dev "$WG_IFACE" 2>/dev/null || true

printf "Setting WireGuard MTU: %s...\n" "$WG_MTU"
ip link set mtu "$WG_MTU" qlen 1000 dev "$WG_IFACE"

# ---------------------------------------------------------------------------
# Enable IPv4 forwarding
# ---------------------------------------------------------------------------

# Required for full-tunnel routing, e.g. client AllowedIPs = 0.0.0.0/0.
#
# Packet path:
#   client 10.1.10.x -> wg0 -> eth0 -> docker bridge/host -> internet
#
# Without this, the container receives packets from VPN clients but will not
# route them onward.
printf "Checking IPv4 forwarding...\n"

if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
    printf "WARNING: net.ipv4.ip_forward is not enabled inside the container.\n" >&2
    printf "WARNING: Set this in docker compose with: sysctls: [net.ipv4.ip_forward=1]\n" >&2

    # Try to enable it, but do not hard-fail if Docker mounted sysctl read-only.
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
fi

printf "IPv4 forwarding state: "
cat /proc/sys/net/ipv4/ip_forward

# ---------------------------------------------------------------------------
# Configure baseline firewall/NAT rules
# ---------------------------------------------------------------------------

printf "Deleting existing baseline iptables rules if present...\n"

# Allow new/forwarded traffic from VPN clients out through the container's
# default egress interface.
"$IPT" -D FORWARD \
    -i "$WG_IFACE" \
    -o "$egress_iface" \
    -s "$WG_SUBNET" \
    -j ACCEPT 2>/dev/null || true

# Allow return traffic from the egress interface back to VPN clients.
"$IPT" -D FORWARD \
    -i "$egress_iface" \
    -o "$WG_IFACE" \
    -d "$WG_SUBNET" \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null || true

# Masquerade VPN client traffic leaving via eth0, so replies come back through
# the container instead of trying to route directly to 10.1.10.0/24.
"$IPT" -t nat -D POSTROUTING \
    -s "$WG_SUBNET" \
    -o "$egress_iface" \
    -j MASQUERADE 2>/dev/null || true

printf "Configuring baseline iptables forwarding/NAT rules...\n"

"$IPT" -A FORWARD \
    -i "$WG_IFACE" \
    -o "$egress_iface" \
    -s "$WG_SUBNET" \
    -j ACCEPT

"$IPT" -A FORWARD \
    -i "$egress_iface" \
    -o "$WG_IFACE" \
    -d "$WG_SUBNET" \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT

"$IPT" -t nat -A POSTROUTING \
    -s "$WG_SUBNET" \
    -o "$egress_iface" \
    -j MASQUERADE

# ---------------------------------------------------------------------------
# Optional custom DNAT/service rules
# ---------------------------------------------------------------------------

# This is where nginx DNAT rules belongs. For example:
#
#   VPN client -> 10.0.10.204:443
#   DNAT       -> nginx container 172.20.0.2:443
#
# This is separate from full-tunnel internet routing.
if [[ -f "$CUSTOM_IPTABLES_SCRIPT" ]]; then
    printf "Loading custom iptables script: %s\n" "$CUSTOM_IPTABLES_SCRIPT"

    # Export variables so /config/iptables.sh can reuse them.
    export IPT
    export WG_IFACE
    export WG_SUBNET
    export egress_iface

    # shellcheck source=/dev/null
    source "$CUSTOM_IPTABLES_SCRIPT"
fi

# ---------------------------------------------------------------------------
# Apply WireGuard peer configuration
# ---------------------------------------------------------------------------

if [[ ! -f "$WG_CONFIG" ]]; then
    printf "ERROR: WireGuard config file missing: %s\n" "$WG_CONFIG" >&2
    exit 1
fi

printf "${nl}Applying WireGuard config: %s\n" "$WG_CONFIG"
wg setconf "$WG_IFACE" "$WG_CONFIG"

printf "Bringing WireGuard interface up...\n"
ip link set "$WG_IFACE" up

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

printf "${nl}Active network interfaces:\n"
ip addr

printf "${nl}Active IPv4 route table:\n"
ip -4 route

printf "${nl}IPv4 forwarding state:\n"
sysctl net.ipv4.ip_forward

printf "${nl}iptables filter table:\n"
"$IPT" -L -n -v

printf "${nl}iptables nat table:\n"
"$IPT" -t nat -L -n -v

printf "${nl}Active WireGuard config:\n"
wg show "$WG_IFACE"

# This validates container internet connectivity. It does not prove that VPN
# client forwarding works, but it is useful for catching basic DNS/routing
# failures inside the container.
printf "${nl}Container IPv4 connectivity validation:\n"
/bin/ping -4 -q -c 1 ipv4.google.com || true

printf "${nl}Running...\n"

# Keep the container alive while boringtun is running. If boringtun exits, the
# script exits non-zero so Docker restart policy can restart the container.
wait "$wireguard_pid"

printf "${nl}WARNING: WireGuard process terminated; exiting for container restart.${nl}"
exit 1
