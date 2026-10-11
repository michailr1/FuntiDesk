# desk.funti.cc — deployment state

Дата: 2026-10-11

## Production

- URL: `https://desk.funti.cc`
- Deployed source commit: `ea4528fa653a8f2a8af93ff3a35e07870a67b660`
- Release path: `/opt/funtidesk-web/releases/ea4528fa653a8f2a8af93ff3a35e07870a67b660/`
- Current symlink: `/opt/funtidesk-web/current`
- Caddy config: `/opt/remnawave/caddy/Caddyfile`
- Caddy serves the site from `/usr/share/caddy` inside its existing container mapping.

## Rollback material

- `/opt/funtidesk-web/backups/Caddyfile.pre-deploy`
- `/opt/funtidesk-web/backups/Caddyfile.before-site-block`
- `/opt/funtidesk-web/backups/default-webroot/`
- `/opt/funtidesk-web/backups/caddy-default-webroot.tar`

Rollback must restore the previous Caddy configuration/web root, validate the Caddy config, then reload Caddy. Do not alter FuntiDesk server identity or the hbbs/hbbr ports.

## Acceptance 2026-10-11

- Caddy config validation: PASS
- Caddy reload: PASS
- HTTP → HTTPS: `308`
- HTTPS: `200`
- TLS certificate: Let's Encrypt, valid through 2027-01-09 at acceptance time
- Page title: `FuntiDesk · Живые соединения`
- `styles.css`: `200`
- `app.js`: `200`
- `assets/funtidesk-mark.svg`: `200`
- hbbs/hbbr: running; restart count remained 0 during deployment
- TCP `21115`, `21116`, `21117`: listening after deployment
- UDP `21116`: listening after deployment
- DNS/firewall/server identity: unchanged

Known non-blocking item: explicit request to `/favicon.ico` returns `404`; the page declares the SVG favicon at `assets/funtidesk-mark.svg`.

Acceptance marker:

`FUNTIDESK_WEB_DEPLOY_OK=true`
