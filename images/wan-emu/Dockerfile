# images/wan-emu/Dockerfile — built on staging only (labimages stage)
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iputils-ping \
 && rm -rf /var/lib/apt/lists/*
# the harness lib + profiles are copied in at build time from the repo checkout
COPY scripts/scenarios/scen-lib.sh /opt/scen/scripts/scenarios/scen-lib.sh
COPY scenarios/profiles/ /profiles/
COPY images/wan-emu/wan-emu.sh /usr/local/bin/wan-emu.sh
ENV SCEN_PROFILES=/profiles SCEN_REPO=/opt/scen
ENTRYPOINT ["/usr/local/bin/wan-emu.sh"]
CMD ["show"]
