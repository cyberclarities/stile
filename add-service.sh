#!/usr/bin/env bash
# Add a service to the shared proxy.
#
#   ./add-service.sh NAME HTTPS_PORT UPSTREAM_PORT [--tls-upstream]
#
#   NAME            Lowercase project name, e.g. "tern". Becomes the site file
#                   name, the env prefix (TERN_), and the upstream alias
#                   (tern-web).
#   HTTPS_PORT      Port users type in the browser, e.g. 9443. Must be > 1024
#                   and not already used by another site.
#   UPSTREAM_PORT   Port the app listens on inside its container.
#   --tls-upstream  The app speaks HTTPS itself (like plumb). nginx connects
#                   with TLS and does not verify the app's certificate.
#
# It writes sites/NAME.conf.template, adds the port to compose.yaml, appends
# the settings to .env.example (and .env, if present), and writes a starter
# docker-compose.nginx.yml for the project into service-template/out/.
# Nothing is started. Review, then: docker compose up -d --build
set -euo pipefail
cd "$(dirname "$0")"

die() { printf 'add-service: %s\n' "$*" >&2; exit 1; }

[ $# -ge 3 ] || { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

name=$1; port=$2; up_port=$3; tls=${4:-}
[[ $name =~ ^[a-z][a-z0-9-]*$ ]]   || die "NAME must be lowercase letters, digits and dashes, starting with a letter."
[[ $port =~ ^[0-9]+$ ]] && [ "$port" -gt 1024 ] && [ "$port" -lt 65536 ] \
                                   || die "HTTPS_PORT must be a number between 1025 and 65535."
[[ $up_port =~ ^[0-9]+$ ]]         || die "UPSTREAM_PORT must be a number."
[ -z "$tls" ] || [ "$tls" = "--tls-upstream" ] || die "Unknown option: $tls"

var=$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')
alias="$name-web"
site="sites/$name.conf.template"

[ -e "$site" ] && die "$site already exists."
grep -q "listen $port ssl" sites/*.conf.template 2>/dev/null && die "Port $port is already used by another site."
grep -q '# <<< service ports' compose.yaml || die "compose.yaml is missing the '# <<< service ports' marker."

if [ -n "$tls" ]; then
    scheme=https
    up_tls='        proxy_ssl_verify off;          # app certificate is self-signed\n        proxy_ssl_server_name off;\n'
else
    scheme=http
    up_tls=''
fi

# Site template.
awk -v N="$name" -v V="$var" -v P="$port" -v S="$scheme" -v T="$up_tls" '
    { gsub(/__NAME__/, N); gsub(/__VAR__/, V); gsub(/__PORT__/, P); gsub(/__SCHEME__/, S)
      if (index($0, "__UPSTREAM_TLS__")) { sub(/__UPSTREAM_TLS__/, ""); gsub(/\\n/, "\n", T); printf "%s", T }
      print }
' service-template/service.conf.in > "$site"

# Port mapping, inserted just above the end marker.
tmp=$(mktemp)
awk -v L="      - \"\${${var}_HTTPS_PORT:-$port}:$port\"" '
    /# <<< service ports/ { print L } { print }
' compose.yaml > "$tmp" && cat "$tmp" > compose.yaml && rm -f "$tmp"

# Settings.
block=$(printf '\n# %s\n%s_SERVER_NAME=localhost\n%s_UPSTREAM=%s:%s\n%s_HTTPS_PORT=%s\n%s_MAX_BODY=10m\n' \
    "$name" "$var" "$var" "$alias" "$up_port" "$var" "$port" "$var")
printf '%s\n' "$block" >> .env.example
[ -f .env ] && printf '%s\n' "$block" >> .env

# Starter override for the project.
mkdir -p service-template/out
sed -e "s/__NAME__/$name/g" -e "s/__ALIAS__/$alias/g" \
    service-template/docker-compose.nginx.yml.in > "service-template/out/$name.docker-compose.nginx.yml"

cat <<EOF
Added $name.

  Site:      $site
  Port:      https://<${var}_SERVER_NAME>:$port  (compose.yaml)
  Settings:  ${var}_* in .env.example$( [ -f .env ] && printf ' and .env' )
  Project:   service-template/out/$name.docker-compose.nginx.yml

Next:
  1. Copy that override into the $name project as docker-compose.nginx.yml and
     set the service name in it to $name's web container.
  2. In $name's .env:  COMPOSE_FILE=<its compose file>:docker-compose.nginx.yml
  3. Here:   docker compose up -d --build
  4. There:  docker compose up -d
EOF
