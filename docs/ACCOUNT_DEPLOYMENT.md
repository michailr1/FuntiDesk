# Кабинет FuntiDesk на Core

Действующее решение владельца от 2026-10-17 — [ADR-013](ADR-013-core-only-account.md): основная SQLite-база на Core, без witness и DE. Старые отчёты от 14–15 октября описывают прежнюю архитектуру. Задача текущего обновления — убрать её обязательную зависимость, сохранив нынешние данные.

## Состав

- `account` — API аккаунтов, SQLite, избранное и история.
- `mail` — SMTP/Postfix/OpenDKIM для кодов входа.
- Используются уже существующие Caddy и hbbs/hbbr. Новые сервисы не нужны.

Данные — `/opt/funtidesk-account/data/account.sqlite3`, секреты — в закрытом `secrets/`, env — `/opt/funtidesk-account/account.env` (`0600`). Account key, DKIM и hbbs identity сохраняются. API/SMTP не имеют публичных портов; аккаунт подключён только к frontend и SMTP. Для схемы v4 не нужны namespace, witness key, recovery directory или адрес DE.

## Обновление

Работать из чистого закреплённого `/opt/funtidesk-account-source`. Проверить source CI, SHA256 archive и image ID/label. Обновлять только account API через существующий Compose/env, сохранив mail image, Caddy, resolver и данные. Не запускать `prepare` или `initialize` на существующей базе.

Перед первым обновлением v3→v4 остановить только API, создать закрытую SQLite Online Backup-копию и проверить её целостность. На отдельной копии применить ту же `schema-local.sql`: прикладные таблицы должны совпасть побайтово по значениям. Миграция удаляет только `recovery_state` и её триггеры; текущие изменения и отзывы остаются. После v4 старый API v3 не запускается, старую базу ради отката не восстанавливать.

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

При обновлении только API Caddy и webroot пересоздавать не нужно. Текущая статическая поставка — `3c327e5f4e19`: автообновление списков и `/connect/`. Браузерные маршруты WSS используют существующую сеть hbbs/hbbr. Вход в кабинет не является разрешением удалённого сеанса.

## Проверка

Проверять schema v4, `integrity_check`, отсутствие witness в активном Compose/env/сетях, неизменность keys/идентичностей и остальных контейнеров. HTTP `/health` и bootstrap должны отвечать `200`, запрос session без авторизации — `401`; дополнительно нужен запрос, работающий с DB (реальный вход/обновление списков). Старые простые health-проверки сами по себе не выявляли отказ witness.

[Резервные копии](ACCOUNT_RECOVERY.md), [инцидент](reviews/2026-10-17-account-witness-outage.md), [синхронизация и Windows-поставка](reviews/2026-10-15-account-sync-browser-check.md). Результат текущего обновления будет зафиксирован после применения и проверки.
