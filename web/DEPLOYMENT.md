# desk.funti.cc — состояние деплоя

Дата деплоя: 2026-10-11

## Production

- URL: `https://desk.funti.cc`
- Branch: `michailr/funtidesk-web`
- Deployed source commit: `1ccf6d4b0e881a3b018ebd5e87c44bc6d4c4c306`
- Release: `/opt/funtidesk-web/releases/1ccf6d4b0e881a3b018ebd5e87c44bc6d4c4c306/`
- Active symlink: `/opt/funtidesk-web/current`
- Caddy Compose project/file/service: `caddy`, `/opt/remnawave/caddy/docker-compose.yml`, `caddy`
- Caddyfile: `/opt/remnawave/caddy/Caddyfile` (unchanged)
- Caddy root: `/usr/share/caddy`, mounted read-only from `/opt/funtidesk-web/current`

## Changes

В canonical Compose добавлен единственный mount:

`/opt/funtidesk-web/current:/usr/share/caddy:ro`

Caddy был пересоздан отдельно командой Compose с `--no-deps --force-recreate caddy` и исходным project name `caddy`. В Compose project определён только service `caddy`; другие Compose services не запускались и не пересоздавались. Caddyfile/routing, DNS, firewall, hbbs/hbbr и server identity не изменялись.

## Backup и rollback

Полный backup, снятый из фактически обслуживавшего контейнера перед изменением:

`/opt/funtidesk-web/backups/deploy-20261011T1755Z/`

Содержит:

- `live-webroot/` — все 10 файлов прежнего `/usr/share/caddy`;
- `live-webroot.sha256`, `live-webroot-files.txt` — сверенные перечни и хеши;
- `docker-compose.yml`, `Caddyfile`, `current-symlink` — исходные конфиги и target;
- `pre-recreate-baseline.txt` — состояния контейнеров и listeners;
- `release-payload.SHA256SUMS`, `release-payload.hashes`, `container-payload.hashes` — контрольные хеши;
- `docker-compose.candidate.yml` и `compose-candidate.resolved.json` — проверенная конфигурация кандидата.

Rollback содержимого сайта: переключить `/opt/funtidesk-web/current` на проверенный полный снимок прежнего live root `/opt/funtidesk-web/releases/rollback-live-webroot-20261011T1755Z` и пересоздать только сервис Caddy: `ln -sfn /opt/funtidesk-web/releases/rollback-live-webroot-20261011T1755Z /opt/funtidesk-web/current.next && mv -Tf /opt/funtidesk-web/current.next /opt/funtidesk-web/current && cd /opt/remnawave/caddy && docker compose -p caddy up -d --no-deps --force-recreate caddy`. Хеши rollback release сверены с backup `live-webroot/`. Чтобы откатить только приложение на задокументированный release, можно направить symlink на `ea4528fa653a8f2a8af93ff3a35e07870a67b660` тем же способом. Compose rollback: восстановить `/opt/funtidesk-web/backups/deploy-20261011T1755Z/docker-compose.yml` в `/opt/remnawave/caddy/docker-compose.yml`, затем выполнить `cd /opt/remnawave/caddy && docker compose -p caddy up -d --no-deps --force-recreate caddy`. Caddyfile не менялся.

## Acceptance

- Exact remote branch HEAD до деплоя: `1ccf6d4b0e881a3b018ebd5e87c44bc6d4c4c306`.
- Payload `index.html`, `styles.css`, `app.js`, `assets/funtidesk-mark.svg` проверен по SHA-256 внутри release и через Caddy mount.
- Caddy config validation: PASS (`caddy validate`); Compose candidate: один service `caddy`, mount read-only.
- HTTP: `308` → `https://desk.funti.cc/`.
- HTTPS page: `200`; literal title: `FuntiDesk · Удалённый доступ для своих`.
- `/styles.css`: `200`; `/app.js`: `200`; `/assets/funtidesk-mark.svg`: `200`.
- Caddy container после targeted recreate: running, restart count `0`.
- hbbs/hbbr: те же container IDs до/после, running, restart count `0`.
- TCP `21115`, `21116`, `21117` и UDP `21116`: слушают до/после; процессы docker-proxy для этих портов не менялись.
- DNS, firewall, server identity и Caddyfile не менялись.

## Source checks

Для deployed HEAD выполнены `git diff --check`, HTML parser parse, проверка title/assets-ссылок и скан публичной страницы на личное имя (совпадений нет). JavaScript `app.js` успешно разобран браузерным JavaScript engine через `new Function`; страница также загрузила CSS, JS и logo без ошибок HTTP.

Acceptance marker:

`FUNTIDESK_WEB_DEPLOY_OK=true`
