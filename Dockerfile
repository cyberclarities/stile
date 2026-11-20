# Shared reverse proxy for the projects under ~/source.
#
# nginx-unprivileged runs as uid 101 and never needs root. Every service it
# fronts listens on a port above 1024, so the container needs no capabilities
# at all: compose.yaml drops them and mounts the root filesystem read-only.
FROM nginxinc/nginx-unprivileged:stable-alpine

# openssl issues the local CA and the per-site certificates at startup
# (docker-entrypoint.d/40-local-ca.sh). The base image ships the library, not
# the command.
USER root
RUN apk add --no-cache openssl \
 && mkdir -p /var/lib/stile /etc/nginx/snippets /etc/nginx/certs \
 && chown 101:101 /var/lib/stile

COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/snippets/ /etc/nginx/snippets/
COPY docker-entrypoint.d/40-local-ca.sh /docker-entrypoint.d/40-local-ca.sh
# COPY keeps the build context's file modes. A checkout with 0600 files would
# leave nginx (uid 101) unable to read its own config, so set them here.
RUN chmod 0644 /etc/nginx/nginx.conf \
 && chmod -R a+rX /etc/nginx/snippets \
 && chmod 0755 /docker-entrypoint.d/40-local-ca.sh

USER 101
# The CA and the issued certificates live here. A named volume keeps the CA
# stable across rebuilds, so workstations only have to trust it once.
VOLUME ["/var/lib/stile"]
