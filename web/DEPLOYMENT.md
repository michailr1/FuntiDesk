# desk.funti.cc — production web

Дата деплоя: 2026-10-11 21:29:33 UTC

## Production

- URL: `https://desk.funti.cc`
- Branch: `michailr/funtidesk-web`
- Deployed source commit: `3dcfec732cd43fe4584bc7a0548fc0785161dfa2`
- Release: `/opt/funtidesk-web/releases/3dcfec732cd43fe4584bc7a0548fc0785161dfa2-artifact/`
- Active symlink: `/opt/funtidesk-web/current`
- Caddy Compose project/file/service: `caddy`, `/opt/remnawave/caddy/docker-compose.yml`, `caddy`
- Caddy root: `/usr/share/caddy`, read-only mount from `/opt/funtidesk-web/current`
- Caddyfile and canonical Compose file were not modified; the existing mount was retained.

The release contains only the 12 public payload files listed in `web/artifact/manifest.json` at the deployed commit. `README.md` and `manifest.json` are repository metadata and were not copied into the public webroot. The release files are mode `0444`; directories are mode `0555`.

After the atomic `current` symlink switch, only the Caddy service was recreated to refresh the bind mount sourced through the symlink:

`cd /opt/remnawave/caddy && docker compose -p caddy -f docker-compose.yml up -d --no-deps --force-recreate caddy`

No hbbs/hbbr, DNS, firewall, server identity, or Remnawave routing changes were made.

## Rollback

The immediately previous release, retained unchanged as rollback authority, is:

`/opt/funtidesk-web/releases/95ad0010d105cbf810213778354831d916707f45-artifact/`

Before deployment, the live Caddy webroot and this release had identical paths and SHA-256 hashes (10 files). No duplicate webroot backup was needed; the immediately previous immutable release is the rollback authority.

To roll back the site, atomically point `current` to the previous release, then recreate only Caddy:

`ln -s /opt/funtidesk-web/releases/95ad0010d105cbf810213778354831d916707f45-artifact /opt/funtidesk-web/current.rollback-next && mv -Tf /opt/funtidesk-web/current.rollback-next /opt/funtidesk-web/current && cd /opt/remnawave/caddy && docker compose -p caddy -f docker-compose.yml up -d --no-deps --force-recreate caddy`

## Acceptance

- Exact source branch commit before deployment: `3dcfec732cd43fe4584bc7a0548fc0785161dfa2`; manifest sizes and SHA-256 values were verified against the commit blobs before switching.
- HTTP: `308` to `https://desk.funti.cc/`.
- HTTPS `/`: `200`; literal HTML title: `FuntiDesk — живые соединения`.
- HTTPS `/index.html`: `200`; SHA-256 `3ecbd249864d06d527c2c6a5dbf0775c48c9731d96a4364b2a758225ed9e784f`.
- All 12 manifest payload URLs returned `200`; response byte sizes and SHA-256 values matched the release: `/`, `/style.css`, `/lab.css`, `/platforms.css`, `/client-ui.css`, `/family.css`, `/app.js`, `/lab.js`, `/platforms.js`, `/family.js`, `/mark.svg`, `/assets/iphone-home.svg`.
- Static reference audit: 38 local HTML/CSS/JS resource references; missing files `0`.
- Browser smoke on the live site: all CSS/JS/mark/iPhone SVG requests returned `200`; all four JavaScript files parsed; P2P and Relay fallback chips worked in the session toolbar; no duplicate DOM IDs, RustDesk identity, or personal names were visible.
- Caddy config validation: `Valid configuration`. Caddy is running with restart count `0`; active mount is `/opt/funtidesk-web/current:/usr/share/caddy:ro`.
- hbbs remained container `16bc3c42555c0dba69b9549b1bc3770a0600b1720c9adeddfea1fd28d0a1c862`, running, restart count `0`.
- hbbr remained container `8d55bbc7ae0994900112a6675a3a3f4474a34df8f60cee6e16e2a6a6ec4fae77`, running, restart count `0`.
- TCP `21115`, `21116`, `21117` and UDP `21116` remained listening and unchanged before/after deployment. All other container IDs remained unchanged; only Caddy was recreated.

`FUNTIDESK_WEB_DEPLOY_OK=true`
