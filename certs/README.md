# Real certificates (optional)

Leave this folder empty and every site gets a certificate from the proxy's
local CA. To use a certificate from your own PKI or a public CA for one site,
drop two files here, named for the site template:

    certs/cairn.crt   full chain, leaf first
    certs/cairn.key   private key, unencrypted

Then `docker compose up -d --force-recreate`. A site with files here uses
them; every other site keeps using the local CA. Keys in this folder are
gitignored. On Docker Desktop (macOS, Windows) file permissions here do not
matter. On a Linux host, nginx runs as uid 101 inside the container and must
be able to read the key: `sudo chown 101 certs/*.key && chmod 600 certs/*.key`.
