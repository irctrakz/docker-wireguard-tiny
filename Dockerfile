FROM alpine:latest as build

RUN \
 echo "***** install cargo ****" && \
 apk add cargo && \
 echo "***** install boringtun via cargo ****" && \
 cargo install boringtun-cli 

FROM alpine:latest

# add local files
COPY --from=build /root/.cargo/bin/boringtun-cli /data/boringtun
COPY scripts/healthcheck.sh /data/healthcheck.sh
COPY scripts/wireguard.sh /data/wireguard.sh

RUN \
 echo "***** install ip mgmt tools *****" && \
 apk add --no-cache wireguard-tools iproute2 libgcc && \
 echo "**** cleanup ****" && \
 rm -rf /tmp/* /var/tmp/*

# ports, volumes, env, etc
ENV WG_SUDO=1
HEALTHCHECK --interval=15m --timeout=30s CMD /bin/bash /data/healthcheck.sh
ENTRYPOINT ["/bin/bash", "/data/wireguard.sh"]
