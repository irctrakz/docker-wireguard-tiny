# docker-wireguard-tiny
A standalone userspace Wireguard (Boringtun) implementation using Alpine Linux.

Resultant container is <20MB uncompressed, and <7MB compressed!

[https://hub.docker.com/r/trakz/wireguard/tags](https://hub.docker.com/r/trakz/wireguard/tags)

Docker CLI:
```
docker run --cap-add=NET_ADMIN -p 51820:51820/udp -v "/path/to/wireguard.conf:/config/wireguard.conf" trakz/wireguard:latest
```

Docker Compose:
```
version: '3.3'
services:
    wireguard:
        container_name: wireguard
        cap_add:
            - NET_ADMIN
        ports:
            - '51820:51820/udp'
        environment:
            - IP_WG_ENV=10.22.10.0/24
        volumes:
            - '/path/to/configs/:/config'
        restart: always
        image: 'trakz/wireguard:latest'
```

`environment` is optional, defaults to `10.0.0.0/24`

Check out [this medium post](https://medium.com/@gstewart_47676/wireguard-made-ridiculously-easy-fa1ef176ce8e) for additional details (e.g how to setup wireguard.conf)
