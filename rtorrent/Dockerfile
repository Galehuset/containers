# Upstream rTorrent (rakshasa) with JSON-RPC + XML-RPC (tinyxml2) over SCGI.
# JSON-RPC is always compiled in upstream (vendored nlohmann/json) and is on by default.

FROM alpine:3.22 AS build

# renovate: datasource=github-tags depName=rakshasa/libtorrent
ARG LIBTORRENT_VERSION=v0.16.28
# renovate: datasource=github-tags depName=rakshasa/rtorrent
ARG RTORRENT_VERSION=v0.16.28

RUN apk add --no-cache \
      build-base autoconf automake libtool pkgconf git linux-headers \
      curl-dev openssl-dev zlib-dev ncurses-dev

WORKDIR /src
RUN git clone --depth 1 --branch "${LIBTORRENT_VERSION}" https://github.com/rakshasa/libtorrent.git \
 && git clone --depth 1 --branch "${RTORRENT_VERSION}"  https://github.com/rakshasa/rtorrent.git

RUN cd libtorrent \
 && autoreconf -fi \
 && ./configure --prefix=/usr --disable-debug \
 && make -j"$(nproc)" \
 && make install \
 && make install DESTDIR=/out

RUN cd rtorrent \
 && autoreconf -fi \
 && ./configure --prefix=/usr --disable-debug --with-xmlrpc-tinyxml2 \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out \
 && rm -rf /out/usr/include /out/usr/lib/pkgconfig /out/usr/lib/*.la /out/usr/lib/*.a /out/usr/share \
 && strip /out/usr/bin/rtorrent /out/usr/lib/libtorrent.so.*

FROM alpine:3.22

RUN apk add --no-cache libcurl libssl3 libcrypto3 zlib ncurses-libs libstdc++ libgcc ca-certificates tini

COPY --from=build /out/usr/ /usr/

# Runs as whatever --user is given; HOME should point at a writable config dir.
ENV HOME=/config
WORKDIR /config

ENTRYPOINT ["/sbin/tini", "--", "rtorrent"]
