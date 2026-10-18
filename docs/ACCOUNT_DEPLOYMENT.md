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

При обновлении только API Caddy и webroot пересоздавать не нужно. Текущая статическая поставка — `3c327e5f4e19`: автообновление списков и `/connect/`. Браузерные маршруты WSS используют существующую сеть hbbs/hbbr. Вход в кабинет не является разрешением удалённого сеанса.

## Проверка

Проверять schema v4, `integrity_check`, отсутствие witness в активном Compose/env/сетях, неизменность keys/идентичностей и остальных контейнеров. HTTP `/health` и bootstrap должны отвечать `200`, запрос session без авторизации — `401`; дополнительно нужен запрос, работающий с DB (реальный вход/обновление списков). Старые простые health-проверки сами по себе не выявляли отказ witness.

[Резервные копии](ACCOUNT_RECOVERY.md), [инцидент](reviews/2026-10-17-account-witness-outage.md), [синхронизация и Windows-поставка](reviews/2026-10-15-account-sync-browser-check.md). [Проверенный результат обновления](reviews/2026-10-17-core-only-account.md): API source `30838e7e51d1`, OCI `sha256:0fad4d8783b861006362dc8d7a599990d22b4a72c47e906cadb4977bab9fac58`; закрытый receipt `integration/api-local-update.json`. Публичный запрос почтового входа исправился с `503` на `202`, письмо пришло во Входящие Gmail. Прежний relay и обе его сети удалены, остальные контейнеры/keys сохранены. Новые mail/server images из CI не включались.

## Отмена удаления: обновление v4→v5 (#58)

План принят архитектором в #68. Реализация ещё не развёрнута: сначала merge и проверенный API artifact из `main`. Новое поле `events.cancelled_at` не меняет существующие доставки/ACK, сессии, ключи и права семьи. `POST /api/account/v1/family/remove/cancel` принимает `{"event_id":42}` с обычной авторизацией/CSRF и идемпотентно отвечает `{"cancelled":true}`. Неизвестное и чужое событие дают одинаковый `400`; без сессии — `401`. `GET /family/removals` добавляет `cancelled_at` в каждую прежнюю строку `deliveries`, без нового массива событий. Только новая привязка устройства пропускает отменённые удаления; существующие очереди и повторная доставка со старым курсором сохраняются. Повтор `/family/remove` с прежним `request_id` не включает отменённое событие заново; новое явное удаление использует новый ID запроса.

Перед изменением рабочей базы выполнить действующую процедуру согласованной копии из [ACCOUNT_RECOVERY.md](ACCOUNT_RECOVERY.md). Для v5 не применять одноразовый `update-library-desk.py --apply`: он рассчитан только на v3→v4. Порядок поставки:

1. Из чистого закреплённого `main` проверить CI, SHA256 artifact, OCI image ID и label `org.opencontainers.image.revision`; загрузить только account image. Зафиксировать прежний image, env и список контейнеров в закрытом каталоге обновления.
2. Через существующий Compose остановить только `account`. Создать SQLite Online Backup, проверить `integrity_check` и `foreign_key_check`, права каталога `0700`, файлов `0600`.
3. На отдельной копии выполнить `account/src/schema-cancel.sql`. Проверить `user_version=5`, целостность, неизменность всех прежних колонок и таблиц, `cancelled_at IS NULL` для всех старых событий. При расхождении остановить обновление; рабочую базу не менять.
4. В существующем закрытом env заменить только `FUNTI_ACCOUNT_IMAGE` на проверенный OCI ID. Команда запуска ниже обновляет только API, который сам применяет ту же миграцию к нынешней базе. Mail, Caddy и остальные проекты не пересоздаются.

```sh
docker compose -p funtidesk-account \
  --env-file /opt/funtidesk-account/account.env \
  -f /opt/funtidesk-account-source/infra/funtidesk-account/compose.yaml \
  stop account
# Согласованная копия и проверка миграции на отдельном пути — до запуска.
docker compose -p funtidesk-account \
  --env-file /opt/funtidesk-account/account.env \
  -f /opt/funtidesk-account-source/infra/funtidesk-account/compose.yaml \
  up -d --no-deps --pull never account
```

После запуска проверить schema v5, целостность, сохранность прежних данных/ключей/контейнеров, реальный вход и списки; на тестовом аккаунте — отмену, привязку нового устройства и ACK старой доставки. Статический helper `update-web-desk.py` допускает обе совместимые схемы v4/v5. Записать image/source, путь копии, проверки и способ отката в PR. После миграции старый API с максимумом v4 несовместим: исправление или откат к совместимому v5 image на текущей базе. Не восстанавливать устаревшую копию ради отката кода, чтобы не вернуть отозванные сессии и права.
