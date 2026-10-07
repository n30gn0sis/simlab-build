# images/svc-targets/Dockerfile — fixed HTTP/DNS targets behind the site-B gateway. Staging build only.
# Build context is the repo root, so COPY paths are repo-relative.
FROM ubuntu:24.04
# Pinned at bundle cut: record the installed nginx-light/dnsmasq versions in the pin review, not here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      nginx-light dnsmasq \
 && rm -rf /var/lib/apt/lists/*
COPY images/svc-targets/nginx.conf /etc/nginx/nginx.conf
COPY images/svc-targets/gen-fixed.sh /usr/local/bin/gen-fixed.sh
COPY images/svc-targets/gen-dnsmasq.sh /usr/local/bin/gen-dnsmasq.sh
COPY images/svc-targets/entrypoint.sh /usr/local/bin/entrypoint.sh
EXPOSE 80 53/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
