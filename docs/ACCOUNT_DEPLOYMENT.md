# Кабинет FuntiDesk на Core

Действующее решение владельца от 2026-10-17 — [ADR-013](ADR-013-core-only-account.md): основная SQLite-база на Core, без witness и DE. Старые отчёты от 14–15 октября описывают прежнюю архитектуру. Обновление применено 2026-10-17; схема v4, действуют только API/SMTP на Core.

## Состав

- `account` — API аккаунтов, SQLite, избранное и история.
- `mail` — SMTP/Postfix/OpenDKIM для кодов входа.
- Используются уже существующие Caddy и hbbs/hbbr. Новые сервисы не нужны.

Данные — `/opt/funtidesk-account/data/account.sqlite3`, секреты — в закрытом `secrets/`, env — `/opt/funtidesk-account/account.env` (`0600`). Account key, DKIM и hbbs identity сохраняются. API/SMTP не имеют публичных портов; аккаунт подключён только к frontend и SMTP. Для схемы v4 не нужны namespace, witness key, recovery directory или адрес DE.

## Обновление

Работать из чистого закреплённого `/opt/funtidesk-account-source`. Проверить source CI, SHA256 archive и image ID/label. Обновлять только account API через существующий Compose/env, сохранив mail image, Caddy, resolver и данные. Не запускать `prepare` или `initialize` на существующей базе.

Перед первым обновлением v3→v4 остановить только API, создать закрытую SQLite Online Backup-копию и проверить её целостность. На отдельной копии применить ту же `schema-local.sql`: прикладные таблицы должны совпасть побайтово по значениям. Миграция удаляет только `recovery_state` и её триггеры; текущие изменения и отзывы остаются. После v4 старый API v3 не запускается, старую базу ради отката не восстанавливать.

Штатная подготовка image: `python3 -B scripts/account/update-library-desk.py <verified-artifact.zip>`, однократное обновление существующей v3 DB — та же команда с `--apply`. Helper читает migration SQL через `git show` из закреплённого binary source, поэтому работает и с сокращённым checkout. `APPLY_STARTED` запрещает слепой повтор; если выполнение остановилось, сначала сверить DB version/image/env/backup и определить завершённые шаги.

После здорового запуска API удалить только контейнер witness-relay проекта `funtidesk-account` и две его неиспользуемые сети. Не применять общий prune или remove-orphans к чужим проектам. DE уже отключён и не включается. Старые служебные файлы можно сохранить в закрытом архиве обновления; рабочий API их не читает.

## Caddy и статические страницы

Сохранять оба действующих override, публичный Caddyfile, SSL volume и все прежние сети:

```sh
docker compose -p caddy \
  --env-file /opt/funtidesk-account/account.env \
  -f /opt/remnawave/caddy/docker-compose.yml \
  -f /opt/funtidesk-account/integration/caddy-account.override.yaml \
  -f /opt/funtidesk-account/integration/caddy-web-client.override.yaml \
  up -d --no-deps --pull never caddy
```

При обновлении только API Caddy и webroot пересоздавать не нужно. Текущая статическая поставка — `30fed457e87e` (2026-10-18): автообновление списков и телефонный `/connect/`, включая PNG для «Домой». [Проверка поставки](reviews/2026-10-18-phone-web-deploy.md). Браузерные маршруты WSS используют существующую сеть hbbs/hbbr. Вход в кабинет не является разрешением удалённого сеанса.

### Телефонный сеанс, ADR-014 / #65

После ревью архитектора и merge статические файлы собираются штатными `npm --prefix web-client run build` и `python3 scripts/web/package.py --write-manifest`. В поставку включается `/connect/app.webmanifest` с MIME `application/manifest+json`; service worker не нужен. Перед поставкой проверить `python3 scripts/web/package.py`.

Одно необходимое изменение Caddy — `manifest-src 'self'` в CSP существующего `handle @connect` блока `desk.funti.cc`, точно по `infra/funtidesk-account/Caddyfile.web-client.fragment`. Сначала сохранить закрытую копию текущего Caddyfile, изменить только эту директиву, проверить `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` в существующем Caddy и применить `caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`. Для `exec -T caddy` использовать тот же Compose с обоими override, что выше; другие блоки, сети и контейнеры не менять. Патч CSP требует ревью до применения (AGENTS.md, правило 12). Принято в #70 и применено на desk 2026-10-18; другие блоки Caddy сохранены.

После поставки проверить HTTP 200 для `/connect/` и `/connect/app.webmanifest`, MIME manifest, фактическую CSP ответа, WSS-сеанс и прежний кабинет. Приёмка — Safari на iPhone в обеих ориентациях, экран «Домой», русская клавиатура/диктовка и настоящий Windows-компьютер. Chromium с эмуляцией телефона эту приёмку не заменяет. При откате вернуть предыдущую статическую поставку штатной процедурой; из CSP убрать только добавленную директиву, затем validate/reload. Остальные сайты и исходные ключи сохраняются.

## Проверка

Проверять schema v4, `integrity_check`, отсутствие witness в активном Compose/env/сетях, неизменность keys/идентичностей и остальных контейнеров. HTTP `/health` и bootstrap должны отвечать `200`, запрос session без авторизации — `401`; дополнительно нужен запрос, работающий с DB (реальный вход/обновление списков). Старые простые health-проверки сами по себе не выявляли отказ witness.

[Резервные копии](ACCOUNT_RECOVERY.md), [инцидент](reviews/2026-10-17-account-witness-outage.md), [синхронизация и Windows-поставка](reviews/2026-10-15-account-sync-browser-check.md). [Проверенный результат обновления](reviews/2026-10-17-core-only-account.md): API source `30838e7e51d1`, OCI `sha256:0fad4d8783b861006362dc8d7a599990d22b4a72c47e906cadb4977bab9fac58`; закрытый receipt `integration/api-local-update.json`. Публичный запрос почтового входа исправился с `503` на `202`, письмо пришло во Входящие Gmail. Прежний relay и обе его сети удалены, остальные контейнеры/keys сохранены. Новые mail/server images из CI не включались.
