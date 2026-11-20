#!/bin/sh
# Give every site a TLS certificate before nginx starts.
#
# Runs from the image's entrypoint, after 20-envsubst-on-templates.sh has
# rendered sites/*.conf.template into /etc/nginx/conf.d/*.conf.
#
# For each rendered site:
#   - certs/<site>.crt and certs/<site>.key supplied on the host? Use them.
#   - Otherwise issue one from a local CA kept in the stile_state volume.
#     The CA is made once. Trust its root on a workstation and every site
#     behind this proxy is trusted, current ones and future ones alike.
#
# A local-CA certificate is reissued at startup when the site's names change
# or it is within 30 days of expiry. It is not renewed while the container
# runs; a restart once a year covers it.
set -eu

ME=40-local-ca
CONF=/etc/nginx/conf.d
USER_CERTS=/etc/nginx/certs
STATE=/var/lib/stile
CA_KEY=$STATE/ca/ca.key
CA_CRT=$STATE/ca/ca.crt
LEAF_DAYS=825        # longest a user-trusted CA may issue for and still satisfy Apple clients
RENEW_SECONDS=2592000 # 30 days

log() { echo "$ME: $*"; }

umask 077
mkdir -p "$STATE/ca" "$STATE/certs" "$CONF/tls"

if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_CRT" ]; then
    log "creating local CA (${PROXY_CA_NAME:-Stile Local CA})"
    openssl req -x509 -nodes -sha256 -days 3650 \
        -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -subj "/CN=${PROXY_CA_NAME:-Stile Local CA}" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$CA_KEY" -out "$CA_CRT" 2>/dev/null
    chmod 644 "$CA_CRT"
fi

found=0
for conf in "$CONF"/*.conf; do
    [ -e "$conf" ] || continue
    found=1
    site=$(basename "$conf" .conf)

    # Every name on every server_name line except the catch-all "_".
    names=$(awk '$1 == "server_name" {
                    for (i = 2; i <= NF; i++) {
                        n = $i; sub(/;$/, "", n)
                        if (n != "_" && n != "") print n
                    }
                }' "$conf" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')

    if [ -z "$names" ]; then
        log "ERROR: $conf has no server_name to issue a certificate for"
        exit 1
    fi

    if [ -s "$USER_CERTS/$site.crt" ] && [ -s "$USER_CERTS/$site.key" ]; then
        crt=$USER_CERTS/$site.crt
        key=$USER_CERTS/$site.key
        log "$site: using supplied certificate certs/$site.crt"
    else
        crt=$STATE/certs/$site.crt
        key=$STATE/certs/$site.key
        stamp=$STATE/certs/$site.names

        if [ -s "$crt" ] && [ -s "$key" ] \
           && [ "$(cat "$stamp" 2>/dev/null)" = "$names" ] \
           && openssl x509 -checkend "$RENEW_SECONDS" -noout -in "$crt" >/dev/null 2>&1; then
            log "$site: local-CA certificate current for: $names"
        else
            san=""
            for n in $names; do
                case "$n" in
                    *:*)       entry="IP:$n" ;;   # IPv6 literal
                    *[!0-9.]*) entry="DNS:$n" ;;  # anything with a letter is a hostname
                    *)         entry="IP:$n" ;;   # IPv4 literal
                esac
                san="${san:+$san,}$entry"
            done
            first=${names%% *}
            ext=$(mktemp)
            csr=$(mktemp)
            printf '%s\n' \
                "subjectAltName=$san" \
                "basicConstraints=critical,CA:FALSE" \
                "keyUsage=critical,digitalSignature" \
                "extendedKeyUsage=serverAuth" > "$ext"
            openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
                -subj "/CN=$first" -keyout "$key" -out "$csr" 2>/dev/null
            openssl x509 -req -sha256 -days "$LEAF_DAYS" \
                -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
                -set_serial "0x$(openssl rand -hex 16)" \
                -extfile "$ext" -out "$crt" 2>/dev/null
            rm -f "$ext" "$csr"
            printf '%s' "$names" > "$stamp"
            log "$site: issued local-CA certificate for: $san"
        fi
    fi

    printf 'ssl_certificate     %s;\nssl_certificate_key %s;\n' "$crt" "$key" > "$CONF/tls/$site.inc"
done

[ "$found" -eq 1 ] || log "WARNING: no sites rendered; nothing in sites/*.conf.template?"
log "trust this CA on workstations: docker compose cp nginx:$CA_CRT ./stile-ca.crt"
