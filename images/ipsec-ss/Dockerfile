# images/ipsec-ss/Dockerfile — strongSwan endpoint, contract E1–E7 (spec §5.2). Staging build only.
FROM ubuntu:24.04
# Pinned at bundle cut: record the installed strongswan version in the pin review, not here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      strongswan-charon strongswan-swanctl libstrongswan-extra-plugins libcharon-extra-plugins \
      iproute2 iputils-ping tcpdump ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# If probe O3 shows save-keys is absent from the noble packages, the labimages
# stage copies locally built .debs into images/ipsec-ss/debs/ and this line
# installs them instead (see Task 14 for the conditional).
COPY images/ipsec-ss/strongswan.d/save-keys.conf /etc/strongswan.d/charon/save-keys.conf
COPY images/ipsec-ss/strongswan.d/logging.conf /etc/strongswan.d/charon-logging.conf
COPY images/ipsec-ss/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN mkdir -p /gt /etc/swanctl/conf.d
HEALTHCHECK --interval=10s --timeout=3s CMD swanctl --list-sas 2>/dev/null | grep -q INSTALLED || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
