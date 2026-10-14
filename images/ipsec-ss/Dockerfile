# images/ipsec-ss/Dockerfile — strongSwan endpoint, contract E1–E7 (spec §5.2). Staging build only.
#
# Probe O3 (state/inventory/ipsec-probes-2026-10-08.md): no noble package ships the
# save-keys plugin. The builder stage compiles just that plugin from Ubuntu's own
# strongswan source package — the same upstream release the runtime's binaries come
# from, fetched through apt's signed index, so there is no new pin and no new trust
# root — and the runtime stage copies the one .so into the distro's plugin directory.
# The version guard below fails the build if the source and binary packages ever drift.
FROM ubuntu:24.04 AS save-keys-builder
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      dpkg-dev build-essential pkg-config libgmp-dev gperf bison flex \
 && mkdir /src && cd /src && apt-get source strongswan \
 && rm -rf /var/lib/apt/lists/* \
 && cd strongswan-*/ \
 && dpkg-parsechangelog -S Version > /save-keys.version \
 && ./configure --disable-defaults --enable-charon --enable-save-keys \
      --enable-ikev2 --enable-nonce --enable-random --enable-pem --enable-x509 >/dev/null \
 && make -j"$(nproc)" >/dev/null \
 && install -m 0644 src/libcharon/plugins/save_keys/.libs/libstrongswan-save-keys.so /save-keys.so

FROM ubuntu:24.04
# Pinned at bundle cut: record the installed strongswan version in the pin review, not here.
# standard-plugins carries openssl/gcm/aesni: without it aes256gcm16 and ecp384 cannot be
# negotiated (staging rehearsal 2026-10-09: "plugin 'gcm': failed to load ... no plugin file").
RUN apt-get update && apt-get install -y --no-install-recommends \
      strongswan-charon strongswan-swanctl libstrongswan-standard-plugins \
      libstrongswan-extra-plugins libcharon-extra-plugins \
      iproute2 iputils-ping tcpdump ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=save-keys-builder /save-keys.so /usr/lib/ipsec/plugins/libstrongswan-save-keys.so
COPY --from=save-keys-builder /save-keys.version /usr/share/doc/strongswan-charon/save-keys.version
RUN [ "$(cat /usr/share/doc/strongswan-charon/save-keys.version)" = "$(dpkg-query -W -f='${Version}' strongswan-charon)" ] \
 || { echo "save-keys plugin built from $(cat /usr/share/doc/strongswan-charon/save-keys.version) but strongswan-charon is $(dpkg-query -W -f='${Version}' strongswan-charon)" >&2; exit 1; }
COPY images/ipsec-ss/strongswan.d/save-keys.conf /etc/strongswan.d/charon/save-keys.conf
COPY images/ipsec-ss/strongswan.d/logging.conf /etc/strongswan.d/charon-logging.conf
COPY images/ipsec-ss/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /gt /etc/swanctl/conf.d
HEALTHCHECK --interval=10s --timeout=3s CMD swanctl --list-sas 2>/dev/null | grep -q INSTALLED || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
