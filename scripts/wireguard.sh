#!/usr/bin/env bash
set -euo pipefail

nl=$'\n-------------------------------------\n'

IP_WG_ENV="${IP_WG_ENV:-10.0.0.0/24}"

if [[ -f /data/boringtun ]]; then
    printf "Starting Wireguard userspace (boringtun)\n"
    mkdir -p /dev/net

    if [[ ! -e /dev/net/tun ]]; then
        mknod /dev/net/tun c 10 200
    fi

    nice -n -10 /data/boringtun --disable-drop-privileges -f wg0 &
    wireguard_pid=$!
else
    printf "WARNING: Wireguard binary not found. This container will not run\n" >&2
    exit 1
fi

# Wait for wg0 to exist rather than only checking wg output.
for _ in {1..20}; do
    if ip link show wg0 >/dev/null 2>&1; then
        break
    fi

    if ! kill -0 "$wireguard_pid" 2>/dev/null; then
        printf "ERROR: boringtun exited before creating wg0\n" >&2
        exit 1
    fi

    printf "Waiting for wg0...\n"
    sleep 1
done

if ! ip link show wg0 >/dev/null 2>&1; then
    printf "ERROR: wg0 was not created\n" >&2
    exit 1
fi

read -r _ _ _ _ iface _ < <(ip route show default)

printf "Setting ipv4 network address options...\n"
ip addr add "$IP_WG_ENV" dev wg0 2>/dev/null || true

printf "Deleting rules if they exist...\n"
iptables-legacy -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables-legacy -D FORWARD -i "$iface" -j ACCEPT 2>/dev/null || true
iptables-legacy -t nat -D POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || true

printf "Configuring iptables-legacy...\n"
iptables-legacy -A FORWARD -i wg0 -j ACCEPT
iptables-legacy -A FORWARD -i "$iface" -j ACCEPT
iptables-legacy -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

if [[ -f /config/iptables.sh ]]; then
    # shellcheck source=/dev/null
    source /config/iptables.sh
fi

printf "Setting network interface mtu...\n"
ip link set mtu 1420 qlen 1000 dev wg0

if [[ -f /config/wireguard.conf ]]; then
    printf "${nl}Setting config...\n"
    wg setconf wg0 /config/wireguard.conf
else
    printf "WARNING: /config/wireguard.conf file is missing. This container cannot start\n" >&2
    exit 1
fi

printf "Bringing interface up...\n"
ip link set wg0 up

printf "${nl}Active network interfaces:\n"
ip addr

printf "${nl}Active network ipv4 route table:\n"
ip -4 route

printf "${nl}iptables-legacy ipv4 nat config:\n"
iptables-legacy -t nat -L -n -v

printf "${nl}Active Wireguard config:\n"
wg show wg0

printf "${nl}IPv4 connectivity validation:\n"
/bin/ping -4 -q -c 1 ipv4.google.com || true

printf "${nl}Running....\n"
wait "$wireguard_pid"

printf "${nl}WARNING: Wireguard process terminated, restarting...${nl}"
exit 1