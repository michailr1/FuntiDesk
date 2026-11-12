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

При обновлении только API Caddy и webroot пересоздавать не нужно. Текущая статическая поставка — `6277d1b4431a` (2026-10-18): автообновление списков и телефонный `/connect/`, включая PNG для «Домой», указатель и системную клавиатуру со спецклавишами из меню (#74), восстановление той же телефонной вкладки в течение пяти минут и атрибуты системного автозаполнения (#76), следование увеличенного экрана за курсором в тачпаде (#77) и одноразовое восстановление после reload по принятому исключению sessionStorage (#78). [Проверка поставки](reviews/2026-10-18-phone-web-deploy.md). Браузерные маршруты WSS используют существующую сеть hbbs/hbbr. Вход в кабинет не является разрешением удалённого сеанса.

### Телефонный сеанс, ADR-014 / #65

После ревью архитектора и merge статические файлы собираются штатными `npm --prefix web-client run build` и `python3 scripts/web/package.py --write-manifest`. В поставку включается `/connect/app.webmanifest` с MIME `application/manifest+json`; service worker не нужен. Перед поставкой проверить `python3 scripts/web/package.py`.

Одно необходимое изменение Caddy — `manifest-src 'self'` в CSP существующего `handle @connect` блока `desk.funti.cc`, точно по `infra/funtidesk-account/Caddyfile.web-client.fragment`. Сначала сохранить закрытую копию текущего Caddyfile, изменить только эту директиву, проверить `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` в существующем Caddy и применить `caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`. Для `exec -T caddy` использовать тот же Compose с обоими override, что выше; другие блоки, сети и контейнеры не менять. Патч CSP требует ревью до применения (AGENTS.md, правило 12). Принято в #70 и применено на desk 2026-10-18; другие блоки Caddy сохранены.

После поставки проверить HTTP 200 для `/connect/` и `/connect/app.webmanifest`, MIME manifest, фактическую CSP ответа, WSS-сеанс и прежний кабинет. Приёмка — Safari на iPhone в обеих ориентациях, экран «Домой», русская клавиатура/диктовка и настоящий Windows-компьютер. Chromium с эмуляцией телефона эту приёмку не заменяет. При откате вернуть предыдущую статическую поставку штатной процедурой; из CSP убрать только добавленную директиву, затем validate/reload. Остальные сайты и исходные ключи сохраняются.

## Проверка

Проверять schema v4, `integrity_check`, отсутствие witness в активном Compose/env/сетях, неизменность keys/идентичностей и остальных контейнеров. HTTP `/health` и bootstrap должны отвечать `200`, запрос session без авторизации — `401`; дополнительно нужен запрос, работающий с DB (реальный вход/обновление списков). Старые простые health-проверки сами по себе не выявляли отказ witness.

После каждой выкладки — `python3 scripts/web/check-live.py`: сверяет публичные файлы сайта с `web/manifest.json` и проверяет, что новые адреса API кабинета отвечают `401`, а не `404`. Код выхода `0` — сервер совпадает с `main`, `10` — расхождения (список в отчёте). Тот же скрипт раз в сутки запускает workflow `.github/workflows/site-drift.yml`: при расхождении он держит открытым один issue с меткой `site-drift` и обновляет его текст, при совпадении закрывает. Новый адрес API добавлять в `API_ROUTES` скрипта в том же PR, что и сам адрес.

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

## Отдельное обновление главной страницы

Если меняется только главная, использовать `python3 -B scripts/account/update-web-desk.py --landing-only` из чистого принятого main. Проверяются SHA-256 пяти файлов по manifest (`index.html`, `style.css`, `theme.js`, `mark.svg`, `app.js`); новая директория `<commit>-landing` наследует действующий webroot и заменяет только эти файлы. Cabinet/console и прежний `SOURCE_COMMIT` сохраняются побайтово, включая ранее принятые ограничения сеанса; новый источник главной и `landingOnly=true` записываются в закрытую квитанцию `updates/landing-<commit>/receipt.json`. Общий webroot имеет составное происхождение; `SOURCE_COMMIT` относится к унаследованным страницам.

Режим совместим с действующим API v4: UI #72 и миграция v5 не поставляются. После сверки состава helper переключает webroot существующим способом, пересоздаёт только Caddy, проверяет кабинет/консоль/API и неизменность остальных файлов/контейнеров/env/Caddyfile. При ошибке возвращает предыдущий webroot. Полная поставка без `--landing-only` по-прежнему требует API, совместимого со всем новым интерфейсом.

## Отдельное обновление веб-консоли
`python3 -B scripts/account/update-web-desk.py --console-only` проверяет manifest и заменяет только семь файлов `connect/`: index.html, session.css, session.js, licenses.html, source.html, app.webmanifest, apple-touch-icon.png. Сохранены главная, кабинет, прежний SOURCE_COMMIT, API/DB v4/v5 и соседние сервисы; источник консоли и `consoleOnly=true` — в закрытой квитанции `updates/console-<commit>/receipt.json`. Режимы landing-only/console-only взаимоисключающие. Откат — прежний webroot и штатное пересоздание только Caddy, без изменения DB/ключей. Полная поставка UI #72 всё ещё требует API v5.

### Сжатие веб-консоли (#126)

`connect/session.js` весит 1,1 МБ, сжатый — около 260 КБ; из-за `Cache-Control no-store` телефон скачивает его при каждом открытии. В действующем блоке `desk.funti.cc` в `handle @connect` первой строкой добавить `encode zstd gzip`, как в `infra/funtidesk-account/Caddyfile.web-client.fragment`; остальные строки и блоки не менять. Затем `caddy validate` и `caddy reload` штатной процедурой. Проверка: `curl -sI -H 'Accept-Encoding: gzip' https://desk.funti.cc/connect/session.js` показывает `content-encoding: gzip`; `scripts/web/check-live.py` больше не пишет «отдаётся без сжатия»; веб-консоль на телефоне подключается. Откат — удалить эту строку, validate/reload.
## Caddy пересоздан без дополнений FuntiDesk (решение архитектора 2026-11-11, #121)

Что случилось: общий Caddy пересоздали только из `/opt/remnawave/caddy/docker-compose.yml`, а сети `funtidesk-account-front` и `funtidesk-server` потом подключили вручную. Из-за этого Caddy получил в account-сети случайный адрес вместо `172.31.251.4`. Кабинет доверяет заголовку `X-Funti-Client-IP` только от адреса из `FUNTI_ACCOUNT_TRUSTED_PROXIES`, поэтому он видит всех посетителей сайта под одним адресом Caddy, и лимиты по IP становятся общими для всех. Ошибки в безопасности нет (чужому заголовку не верят), но работа неправильная. `update-web-desk.py` справедливо останавливается на `Compose differs from live Caddy`.

Решение: эталон — репозиторий (`base` + `caddy-account.override.yaml` + `caddy-web-client.override.yaml`, после статистики ещё `caddy-analytics.override.yaml`). Доверенный прокси остаётся фиксированным `172.31.251.4`: разрешать целую подсеть или подстраивать env под случайный адрес не нужно. Фактическое состояние один раз приводится к эталону. Проверку в скрипте не убирать. Подключать сети вручную без пересоздания можно только как временную меру и только с адресом: `docker network connect --ip 172.31.251.4 funtidesk-account-front <контейнер Caddy>`.

Порядок, в спокойное время (соседние сайты прерываются на секунды):

1. Только чтение. Сохранить в закрытый каталог `updates/` вывод `docker inspect` контейнера Caddy и `docker network inspect funtidesk-account-front funtidesk-server`. Убедиться, что `172.31.251.4` в account-сети свободен.
2. Сравнить `docker compose -p caddy -f /opt/remnawave/caddy/docker-compose.yml config caddy` с той же командой плюс `--env-file /opt/funtidesk-account/account.env -f …/caddy-account.override.yaml -f …/caddy-web-client.override.yaml` (пути, как в `update-web-desk.py`). Допустимы отличия только в `networks`: две сети FuntiDesk и `ipv4_address`. Любое другое отличие (образ, порты, тома, Caddyfile) — стоп и отчёт в PR.
3. Записать HTTP-статусы главных страниц всех сайтов из общего Caddyfile (только GET).
4. Пересоздать только Caddy: та же команда из шага 2 с `up -d --no-deps --pull never --force-recreate caddy`.
5. Проверить:
   - образ, порты, тома и набор сетей совпадают с шагом 1;
   - адрес в account-сети — `172.31.251.4`, и он же стоит в `FUNTI_ACCOUNT_TRUSTED_PROXIES` у API;
   - ID остальных контейнеров не изменились, статусы соседних сайтов — как в шаге 3;
   - главная, кабинет и `/connect/` — `200`, `/api/account/v1/library` — `401`, оба WSS — `101`;
   - `config --hash caddy` совпадает с меткой контейнера.
6. Дальше штатно: `update-web-desk.py` (полная поставка), затем раздел «Статистика». После установки статистики `update-web-desk.py` сам добавляет `caddy-analytics.override.yaml`, если файл есть в `/opt/funtidesk-analytics/source`.

Откат шага 4: пересоздать Caddy только из `/opt/remnawave/caddy/docker-compose.yml` и подключить обе сети FuntiDesk, как было до шага 1. Вернётся прежнее состояние вместе с прежней ошибкой адреса.

Если VPN-стек снова пересоздаст Caddy своим compose, сети FuntiDesk пропадут: кабинет и консоль перестанут работать, ежедневная проверка `site-drift` покажет, что адрес API отвечает не `401`. Исправление — шаги 1–5.

## Статистика (ADR-019, #115)

Закрытый отчёт по агрегатам кабинета и hbbs на `https://desk.funti.cc/<закрытый путь>/` за паролем (Caddy Basic Auth). Выкладывается только после принятия ADR-019 владельцем. Непубликуемый путь и пароль не попадают в GitHub, в PR и в чат: путь и логин владелец получает лично, пароль — тоже лично или задаёт сам.

Устройство: отчёт лежит в `/opt/funtidesk-analytics/www`, **вне общего webroot**, и доступен только из защищённого `handle`; общий `file_server` его не видит. Закрытый файл `/opt/funtidesk-analytics/analytics.caddy` (`0600`) с путём и bcrypt-хэшем подключается одной строкой `import`. Нет файла — `caddy validate` не проходит, reload не применяется. Отчёт обновляет systemd-таймер раз в сутки; ошибка аналитики не трогает account, hbbs и Caddy, прежний отчёт остаётся.

Порядок (из чистого принятого `main`; перед изменением Caddyfile — закрытая копия текущего):

```sh
install -d -m 0700 /opt/funtidesk-analytics /opt/funtidesk-analytics/www
git -C /opt/funtidesk-analytics clone --depth 1 https://github.com/michailr1/FuntiDesk.git source   # затем checkout принятого коммита
P=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))')
PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')        # не короче 24 символов: у Basic Auth нет лимита попыток
HASH=$(docker compose -p caddy <те же -f, что выше> exec -T caddy caddy hash-password --plaintext "$PASS")
umask 077; sed -e "s#__PATH__#$P#g" -e "s#__USER__#owner#" -e "s#__HASH__#$HASH#" \
  /opt/funtidesk-analytics/source/infra/funtidesk-analytics/analytics.caddy.template > /opt/funtidesk-analytics/analytics.caddy
```

1. Первый отчёт: `python3 -I /opt/funtidesk-analytics/source/scripts/analytics/publish.py --account-db /opt/funtidesk-account/data/account.sqlite3 --hbbs-db /opt/funtidesk/data/db_v2.sqlite3 --out-dir /opt/funtidesk-analytics/www`.
2. В блок `desk.funti.cc` общего Caddyfile, **перед** последним `handle { file_server }`, добавить одну строку `import /etc/caddy/funtidesk-analytics.caddy`. Другие блоки не менять.
3. Пересоздать только Caddy с третьим override (один раз, соседние сайты прерываются на секунды — в согласованное окно), затем `caddy validate` и `caddy reload`:

```sh
docker compose -p caddy \
  --env-file /opt/funtidesk-account/account.env \
  -f /opt/remnawave/caddy/docker-compose.yml \
  -f /opt/funtidesk-account/integration/caddy-account.override.yaml \
  -f /opt/funtidesk-account/integration/caddy-web-client.override.yaml \
  -f /opt/funtidesk-analytics/source/infra/funtidesk-analytics/caddy-analytics.override.yaml \
  up -d --no-deps --pull never caddy
```

4. Таймер: скопировать `funtidesk-analytics.service` и `.timer` в `/etc/systemd/system/`, `systemctl daemon-reload && systemctl enable --now funtidesk-analytics.timer`.

Проверки: без пароля и с неверным — `401` для `/<путь>/`, `/<путь>/index.html`, `//<путь>/`, `%2F`-вариантов; с паролем — `200`, заголовки `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`, CSP; главная, кабинет, `/connect/` и WSS работают как раньше; `systemctl list-timers` показывает таймер. Откат: удалить строку `import` и третий override, пересоздать Caddy прежней командой, `systemctl disable --now funtidesk-analytics.timer`; данные кабинета и hbbs не затрагиваются.

## Защита входа статистики

Дашборд должен требовать авторизацию и быть защищён от перебора учётных данных. Настройка общей инфраструктурной защиты, её проверки и откат ведутся в закрытой эксплуатационной документации владельца. Публиковать конфигурацию общей инфраструктуры в репозитории FuntiDesk не следует.
