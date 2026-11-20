# Stile

A stile is the set of steps over a field wall: the one place to cross, built so people get through and the stock does not. Same job here.

One Nginx container in front of the projects under `~/source`, replacing the
Caddy container each project used to run for itself. Each project keeps its
own TCP port, so nobody's bookmarks change:

| Project | Users browse to (host port) | Stile forwards to (inside Docker) | Set by |
|---------|------------------------------------|-----------------------------|--------|
| plumb   | `https://<PLUMB_SERVER_NAME>:6443`  | `plumb:6443`, over HTTPS    | `PLUMB_PORT`, 6443 unless set in `plumb/config/plumb.env` |
| cairn   | `https://<CAIRN_SERVER_NAME>:7443`  | `cairn-web:5000`, plain HTTP | `PORT` in `cairn/.env` |
| skerry  | `https://<SKERRY_SERVER_NAME>:8443` | `skerry-web:5000`, plain HTTP | `PORT` in `skerry/.env` |

The two port columns are different things. The first is what people type and
what Stile listens on. The second is where each app listens inside its own
container, on the `stile_net` network, and is never published on the host.
CAIRN and Skerry both run Gunicorn on 5000, and that is fine: each is in its
own container with its own address. Plumb shows 6443 in both columns only
because Plumb serves its own HTTPS on that port inside the container too.

If you change `PORT` in a project's `.env`, change `<NAME>_UPSTREAM` in
`stile/.env` to match. CAIRN's compose file falls back to 5002 when `PORT` is
unset, so keep `PORT=5000` in `cairn/.env` or point `CAIRN_UPSTREAM` at 5002.

Using the proxy is a choice each project makes in its own `.env`. Caddy stays
the default, and switching back is one commented line.

## How it fits together

The proxy owns a Docker network, `stile_net`. A project that opts in loads a
small override file (`docker-compose.nginx.yml`, or `compose.nginx.yaml` for
plumb) that does two things: parks the project's Caddy behind a profile so it
no longer starts, and joins the project's web container to `stile_net` under
a unique alias. Nginx finds it by that alias.

The alias matters. CAIRN and Skerry both call their container `web`, and two
`web`s on one network is a coin toss. `cairn-web` and `skerry-web` are not.

Upstreams are resolved per request, not at startup. A project that is down
returns 502 on its own port; it does not keep nginx from starting or take the
other projects down with it.

## First run

```sh
cd ~/source/stile
cp .env.example .env          # set each *_SERVER_NAME to what users type
docker compose up -d --build
docker compose logs nginx     # shows each certificate issued
```

Then, in each project you want behind the proxy:

1. Uncomment `COMPOSE_FILE` in that project's `.env` (the "Reverse proxy"
   section of its `.env.example` has the line).
2. Stop the project's Caddy, which is still holding the port:
   `docker compose rm -sf caddy` (cairn, skerry). Plumb frees 6443 on the
   next `up`.
3. `docker compose up -d`

Order matters on the first run. The proxy creates `stile_net`; a project
started before it fails with an error that the external network
`stile_net` could not be found. After that, either side can restart on its own.

Port collisions are the other first-run snag. If `docker compose up` here
reports a port already allocated, a project's Caddy (or plumb itself) is
still bound to it. Step 2 clears it, then `docker compose up -d` here again.

## Certificates

Every site gets a certificate at startup from a local CA the proxy creates
once and keeps in the `stile_state` volume. Trust that CA on a
workstation and every site behind this proxy is trusted, including ones added
later:

```sh
docker compose cp nginx:/var/lib/stile/ca/ca.crt ./stile-ca.crt
```

On macOS, open the file in Keychain Access, add it to the System keychain,
and set it to Always Trust. This replaces the per-project Caddy roots that
workstations trusted before; those can be removed once every project is
moved over.

A site's certificate is reissued at startup when its names change or it is
within 30 days of expiry. It is not renewed while the container keeps
running, so restart the proxy at least once a year.

For a real certificate on one site, see `certs/README.md`.

## What carried over from Caddy, and what changed

Carried over:

- **Forwarded headers.** `X-Forwarded-For` is overwritten with the connecting
  address, the way Caddy did it. CAIRN's audit trail depends on that (see the
  note in `cairn/app/routes/auth.py`). `X-Forwarded-Proto` and
  `X-Forwarded-Host` are set for the apps' ProxyFix.
- **Wrong-host requests are refused.** A request whose Host is not the site's
  name gets 421, never the app. The apps trust `X-Forwarded-Host`, so passing
  arbitrary hosts through would let a client choose the host in generated
  links.
- **CAIRN's 10-minute timeouts and uploads.** `CAIRN_MAX_BODY` defaults to
  512m to match `MAX_UPLOAD_MB`. Nginx's own default is 1 MB, which would have
  broken restores outright. Request bodies stream to the app instead of
  spooling to disk, as with Caddy.
- **Security headers.** Each app already sets its own. The proxy fills in
  `nosniff`, `X-Frame-Options`, `Referrer-Policy` and HSTS only when the app
  sent none, so plumb's stricter `no-referrer` is left alone.
- **gzip**, and `http://` on an HTTPS port redirects to `https://`.

Changed:

- One CA for all projects instead of one per project.
- Plumb still terminates its own TLS, so nginx speaks HTTPS to it and does not
  verify plumb's self-signed certificate. That hop stays on the `stile_net`
  network. If plumb gains a plain-HTTP mode, switch its `proxy_pass` to
  `http://` and drop the `proxy_ssl_*` lines.
- Each project's `SERVER_NAME` is no longer read by a proxy. Set the matching
  `<NAME>_SERVER_NAME` here, and keep `BASE_URL` in the project's `.env`
  pointed at the same name and port, since the apps still use it for links.

## Adding a service

```sh
./add-service.sh tern 9443 8000                 # app speaks plain HTTP on 8000
./add-service.sh tern 9443 8443 --tls-upstream  # app speaks HTTPS itself
```

That writes `sites/tern.conf.template`, adds port 9443 to `compose.yaml`,
appends `TERN_*` settings to `.env.example` (and `.env`), and writes a starter
override for the project to `service-template/out/tern.docker-compose.nginx.yml`.
It starts nothing. Review the output, copy the override into the project, set
`COMPOSE_FILE` in the project's `.env`, then `docker compose up -d --build`
here and `docker compose up -d` there.

Done by hand, it is the same three edits: a template in `sites/`, a port line
in `compose.yaml`, and the `<NAME>_*` variables in `.env`. Only variables named
`*_SERVER_NAME`, `*_UPSTREAM` and `*_MAX_BODY` are substituted into templates,
so nginx's own `$variables` are never touched.

## Requirements

Docker Compose 2.24.4 or later. Plumb's override uses `ports: !reset []` to
stop publishing 6443, which older versions do not understand. Check with
`docker compose version`.

## Files

```
compose.yaml                     the proxy container, ports, network, hardening
Dockerfile                       nginx-unprivileged plus openssl
.env.example                     per-service names, upstreams, ports, body limits
nginx/nginx.conf                 global settings, resolver, header defaults
nginx/snippets/proxy.conf        forwarded headers, streaming, security headers
nginx/snippets/https-listener.conf  http2, http-to-https redirect
sites/*.conf.template            one per service
docker-entrypoint.d/40-local-ca.sh  local CA and per-site certificates
certs/                           optional real certificates
add-service.sh                   scaffolds a new service
service-template/                what add-service.sh fills in
```
