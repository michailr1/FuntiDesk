# Развёртывание основного кабинета на desk.funti.cc

Владелец разрешил продолжить основной запуск 2026-10-14. Кабинет, API, SMTP и resolver hbbs размещаются на Core (`desk.funti.cc`). Действующие данные и ключ сервера FuntiDesk сохраняются. Доступ через MCP служит каналом управления Core.

## Закреплённая поставка и подготовка

`infra/funtidesk-account/account-release.json` закрепляет успешный `Account checks` основного commit `a42f05fa`: run, artifact, SHA256 ZIP и Docker archive, IDs и source label образов. Фактический ZIP проверен перед подготовкой. `prepare-desk.py` заново проверяет эти значения на Core, меняет только теги archive на имена с исходным SHA, сверяет загруженные image IDs и создаёт отдельный `/opt/funtidesk-account`.

Команда выполняется от root из чистого закреплённого checkout; временный HTTPS URL ZIP передаётся в stdin и не сохраняется в Git или конфигурации:

```sh
python3 scripts/account/prepare-desk.py --artifact-url-stdin
```

Существующий account path и неожиданное содержимое целевых image tags завершают подготовку отказом. Ключи создаются только на Core и не выводятся. Данные принадлежат UID/GID `10001`, resolver directory допускает группу `10001`; закрытые account/witness keys имеют `0400`, DKIM — `0600`. `.env` фиксирует проверенные image IDs и новый namespace. Подготовка публикует только публичные SPF/DKIM, основной базы пока не создаёт и контейнеры не запускает.

`python3 scripts/account/stage-desk.py` готовит неизменяемый публичный webroot, сверяет manifest, заменяет только desk-блок в кандидате полного Caddyfile и валидирует его действующим Caddy. Прежний Caddyfile, путь сайта и данные контейнера сохранены в закрытом `/opt/funtidesk-account/integration`. Этот этап готовит переключение; фактическое применение выполняется после проверки закрытого API и почты.

Корень bind-каталога `mail-queue` создаётся как root:root `0755`, с явным `chmod` после `mkdir`: deployment umask `077` не должен лишать Postfix права прохода. Права закрытых подкаталогов очереди сохраняются. В исходной подготовке был `0700`; на закреплённом образе это воспроизведено как аварийная остановка Postfix при обходе очереди. Для уже подготовленного Core сначала прочитать статус/права и безопасные категории ошибок, затем исправить **только корень** `/opt/funtidesk-account/mail-queue` на `0755` и запустить только mail. Не повторять `prepare-desk.py`, не менять права рекурсивно и не пересоздавать ключи. Регрессия `smoke-mail.py` использует пустой настоящий bind mount, подготовленный тем же helper под umask `077`.

Почтовое имя и HELO — `desk.funti.cc` (решение владельца 2026-10-15). PTR исходящего `173.249.195.36` должен возвращать это имя; A уже указывает на тот же IP. Системный hostname `core.funti.cc` сохраняется. SPF/DKIM относятся к домену отправителя `funti.cc`, смена HELO не требует нового DKIM-ключа.

Postfix явно получает `smtp_bind_address=0.0.0.0`: маршрут выбирает исходящий адрес, тогда как `inet_interfaces` остаётся приватным. Без этого Postfix использовал единственный приватный listener IP как source исходящего соединения, что на реальном Core приводило к timeout. Smoke проверяет настоящий Postfix transport через вторую изолированную сеть и отказывает до MAIL/DATA.

Mail bootstrap монтируется read-only из `infra/funtidesk-account/mail-entrypoint.sh` чистого закреплённого deploy checkout, с executable bit из Git. Проверенный image `a42f05fa` сохраняет пакеты и provenance; актуальная конфигурация bootstrap имеет отдельный source commit и SHA256 файла. При обновлении сверить image, source/hash и readonly mount; пересоздать только mail через тот же Compose/env. Не приписывать обновлённый скрипт содержимому старого image.

## Переключение Caddy и откат

`python3 scripts/account/activate-desk.py` предназначен для отдельного шага после выполнения условий включения ниже. Он сверяет staged backup/candidate, исходный webroot, действующий Caddy и его Compose, образ, mounts и сети до изменения файлов. Проверяет приватные HTTP `/health` и unauthenticated session; эти два запроса сами по себе не подтверждают SMTP, свежесть witness или готовность resolver к привязке устройства.

Скрипт пересоздаёт только Caddy через исходный Compose и account override, без загрузки нового образа. После переключения ждёт HTTPS страницы и ответа `401` API в ограниченный срок. Ошибка до попытки recreate возвращает изменённые файлы без перезапуска Caddy; ошибка после начала recreate возвращает исходные Caddyfile, webroot и Compose, затем проверяет HTTPS прежнего сайта. Отказ самого отката выводится отдельно. Account DB и независимое состояние не откатываются. Отдельные unit tests проверяют сбои этих фаз без серверов; приватный HTTP-клиент дополнительно проверяется `smoke-mail.py` на настоящем API.

Активация на Core выполнена 2026-10-15 07:59 UTC после backup/fresh witness/DNS/реальной почты. Настоящий публичный Chromium вход/выход и security checks прошли; [текущий отчёт](reviews/2026-10-15-account-deploy-continuation.md). Реальная M3-приёмка Windows остаётся отдельным условием готовности продукта.

## Условия включения

Перед публичным входом проверить единственную SPF с исходящим IPv4 Core, DNS для нового DKIM, DMARC, прямой/обратный DNS и настоящую доставку. Существующих отправителей SPF и MX сохраняют. Публичные записи подготовка пишет в `/opt/funtidesk-account/dns-records.json` для владельца.

Основной ключ защищают отдельной зашифрованной копией для владельца; нужен его публичный age recipient, приватная age identity остаётся у владельца. Само независимое хранилище получает только машинный witness key и зашифрованные снимки по [ACCOUNT_RECOVERY.md](ACCOUNT_RECOVERY.md).

`scripts/account/backup-desk.py` создаёт раздельные `account-secrets` и `server` архивы в уже существующем root-owned каталоге `0700`. Публичный age recipient передаётся одной строкой stdin или через закрытый `--recipient-file`; приватная identity не требуется. Tar поступает прямо в age, без plaintext backup на диске. Для hbbs используется SQLite Online Backup в RAM с `integrity_check`, включая committed WAL; identity сверяется до и после операции. Максимальный snapshot — 64 МиБ, нужны Python 3.11+ и age. Пример: `python3 scripts/account/backup-desk.py backup --component server --output /opt/funtidesk-account/backups/server-<UTC>.tar.gz.age`.

Архив `account-secrets` содержит существующие account/witness/DKIM keys и metadata; он не содержит основной account DB и не разрешает откат независимого witness. Файлы не перезаписываются, результат содержит только component/SHA256/размер. После переноса ciphertext на независимую машину выполнить `verify-copy --artifact <путь> --expected-sha256 <digest с Core>`. Локальные round-trip тесты с отдельной тестовой age identity проверяют расшифрование и WAL snapshot; проверка production расшифрования остаётся у владельца.

Новые сети проверяют против маршрутов и Docker subnets до применения. Resolver требует собственного закреплённого server release, с сохранением `/opt/funtidesk/data`. Caddy получает только отдельную frontend-сеть и изменение блока `desk.funti.cc`. Общий конфиг валидируют до применения, другие блоки сохраняют. Новый webroot публикуют отдельным неизменяемым выпуском; Caddy обновляют с исходным Compose и собственным override.

Первую инициализацию пустой базы выполняют явно после проверки независимого состояния. Восстановление и откат интерфейса не возвращают старые отзывы. Аккаунты первого этапа хранятся без автоматического удаления; код входа действует 5 минут, сессия — 30 дней по текущей реализации. Политику удаления данных расширяют отдельным решением, без очистки действующих отзывов.

Фактические результаты включения, состояние DNS, проверка браузера и реальные клиентские сценарии фиксируются в отчёте после выполнения. Успешная подготовка не означает успешный вход или завершённую M3-приёмку.

## Действующие серверные конфигурации

После обновления 2026-10-15 `/opt/funtidesk/repo` оставлен на прежнем commit и не является source действующего resolver release. Штатный build helper выполнен из `/opt/funtidesk-account-source`, release `funtidesk-server-a42f05faa3c4`. Identity/data mount, порты и прежняя сеть сохранены. Для последующих операций hbbs/hbbr использовать весь набор:

```sh
docker compose -p funtidesk-server \
  --env-file /opt/funtidesk/server.env \
  --env-file /opt/funtidesk-account-source/infra/funtidesk-server/server-release.env \
  -f /opt/funtidesk-account-source/infra/funtidesk-server/compose.yaml \
  -f /opt/funtidesk-account/integration/hbbs-identity.override.yaml \
  up -d --no-deps --pull never hbbs hbbr
```

Старый default deploy без этого override может потерять resolver mount или вернуть прежний release. `/opt/funtidesk/DEPLOYED_COMMIT` фиксирует source tools `cf51dda4` на момент обновления; source server binaries — `a42f05fa`. Предыдущее состояние image IDs сохранено в закрытом `/opt/funtidesk-account/integration/server-before.json`.

Account project использует `/opt/funtidesk-account/account.env` и `/opt/funtidesk-account-source/infra/funtidesk-account/compose.yaml`. Для изменения mail выполнять `up -d --no-deps --pull never mail` с этим project/env/Compose; проверять readonly executable bootstrap и pinned package image. Не повторять подготовку и инициализацию существующих хранилищ.

DE witness использует project `funtidesk-account-witness`, env `/opt/funtidesk-account-witness/witness.env` и Compose из `/opt/funtidesk-account-witness-tls-source/infra/funtidesk-account/compose.witness.yaml` (`6316cd27`). Установленный hourly TLS sync проверен на работающем сервисе и требует сохранённого loopback admin. Основной account key на DE не переносится.

## Обновление только API без повторной инициализации

`account-release.json` остаётся базовой поставкой `a42f05fa`, включая relay/witness. `account-api-release.json` отдельно закрепляет проверенную CI-поставку SMTP/MIME hotfix `2051ad38`; из этого archive для работающего API применяется только image `funtidesk-account`. Остальные образы этой поставки не объявляются действующими. Это сохраняет проверку точного image/source уже установленного relay и отдельного witness.

Для обновления существующего Core: сверить успешный run/source/artifact digest, проверить ZIP, все внутренние SHA256 и classic/OCI IDs helper-функциями `verify_archive`/`source_qualified_archive` с API manifest. Загрузить образы с тегами исходного SHA; не запускать `prepare`, `initialize`, `restore` или `witness-init`. Сохранить закрытый `account.env.before`, проверить fresh signed witness Head, заменить в `account.env` только `FUNTI_ACCOUNT_IMAGE` на проверенный API image ID и выполнить существующим Compose/env `up -d --no-deps --pull never account`.

Проверить health/session, UID/сети/публичные порты, точный image/source, неизменность keys/namespace и остальных контейнеров; повторить signed Head. При неуспешной готовности вернуть только прежнее значение image/env и API container. DB/witness не откатываются. Hotfix меняет только `account/src/mail.rs`, без миграции данных/протокола. На этом этапе публичный web оставался исходного `a42f05fa`; добавление отдельного браузерного кандидата описано ниже.

## Действующий публичный Caddy

После включения 2026-10-15 сохранять оба override при последующем recreate Caddy: account добавляет frontend-сеть кабинета, web-client — существующую сеть hbbs/hbbr. SSL volume и исходные сети сохраняются. Действующая команда (base `.env` отсутствует на момент запуска):

```sh
docker compose -p caddy \
  --env-file /opt/funtidesk-account/account.env \
  -f /opt/remnawave/caddy/docker-compose.yml \
  -f /opt/funtidesk-account/integration/caddy-account.override.yaml \
  -f /opt/funtidesk-account/integration/caddy-web-client.override.yaml \
  up -d --no-deps --pull never caddy
```

Вызов одного исходного Compose потеряет frontend-сеть; отсутствие browser overlay отключит веб-сеансы. Текущий webroot — `/opt/funtidesk-web/releases/3c327e5f4e19e5f2fd960d2fa52c98b72ea8990a-web`: полный сайт, кабинет с избранным/историей и `/connect/`. Действующий API — source `508b1d0e99f0046a97b5f46f74d92ed2aaa31d40`, OCI image `sha256:b1d0ad554d67b7097412420c7ff89b95d03cb587f5f0c02f8ff13771579740e4`, схема DB — v3. API подтверждает закрытый `integration/api-library-update.json`, текущее статическое обновление — `updates/web-3c327e5f4e19/receipt.json`; исходные stage и MIME receipts описывают прежние этапы. `ACTIVATED` защищает от повторного первого включения. Откат Caddy/webroot не откатывает account DB, независимое состояние и отзывы.


## Первое browser-only включение, 2026-10-15 (история)

На `https://desk.funti.cc/connect/` включён отдельный кандидат из source `508b1d0e99f0046a97b5f46f74d92ed2aaa31d40`. Штатный `scripts/account/update-browser-desk.py` сверил прежний и новый manifest, сохранил страницы кабинета и изменил только desk-блок Caddy/добавил одну существующую сеть. API, его DB v2, mail, relay, hbbs/hbbr, остальные контейнеры и ключи сохранены. Ни initialize, ни restore не выполнялись.

Публичные HTML/JS совпадают с проверенной сборкой, ответы `no-store`. HTTPS/WebSocket upgrade на обоих `/ws/rendezvous` и `/ws/relay` даёт `101` для нашего Origin и `403` для чужого. Cookie/Authorization не передаются в hbbs/hbbr. Настоящий Windows-сеанс ещё требует приёмки; пользователь подтвердил наличие двух компьютеров.

Закрытая запись — `/opt/funtidesk-account/updates/browser-508b1d0e99f0/receipt.json`, полный прежний и кандидатный Caddyfile рядом. Откат этого кандидата возвращает прежний Caddyfile/webroot и запускает Caddy только с base + account overlay; DB и независимое состояние не откатываются. Повторный запуск helper поверх уже включённого кандидата намеренно отклоняется для проверки текущего состояния. Этот receipt описывает прежнюю смешанную поставку. После обновления ниже нельзя применять её старую процедуру отката как описание текущего состояния.


## Действующее обновление API v3 и полного кабинета, 2026-10-15

`infra/funtidesk-account/account-library-release.json` закрепляет успешный push run [38732381862](https://github.com/michailr1/FuntiDesk/actions/runs/38732381862), source `508b1d0e99f0`, artifact `11971128815`, SHA256 ZIP `fe5a6d7be5de94e968a2d9daff8baa7b3a35e31c5f9779ef62fc17dc1053905b`. Базовый relay/witness остаётся `a42f05fa`; другие образы из нового archive не включались.

Штатный `scripts/account/update-library-desk.py <artifact.zip>` проверяет archive и готовит source-qualified image без переключения. Однократное `--apply` из чистого source `8aec8df11cfa` выполнило миграцию существующей v2 DB, заменило только API image в env, проверило signed witness Head и private health/session/library, затем переключило полный webroot и пересоздало только Caddy с обоими override. Ключи, namespace, mail/relay/hbbs/hbbr, остальные контейнеры, SSL volume и Caddy image сохранены. Initialize/restore не выполнялись; receipt — `/opt/funtidesk-account/integration/api-library-update.json`. Публичные страницы вернули `200`, неавторизованная library — `401`.

После миграции запрещено запускать прежний API v2 на новой DB или восстанавливать старую SQLite/witness для отката. При отказе нужен совместимый v3 image; helper откатывает только webroot, а прежний API возвращает исключительно если DB осталась v2. `APPLY_STARTED` запрещает слепой повтор. Приёмка синхронизации на двух Windows-службах и настоящего браузерного сеанса остаётся открытой: [отчёт](reviews/2026-10-15-account-sync-browser-check.md).


## Обновление только файлов работающего кабинета

`python3 -B scripts/account/update-web-desk.py` из чистого source предназначен для уже работающего Core с API/DB v3. Helper проверяет private API readiness, точный Compose/config hash действующего Caddy и manifest нового сайта; сохраняет старый webroot, переключает новый immutable release и пересоздаёт только Caddy с обоими override. API, остальные контейнеры, Caddyfile/env, image, порты, SSL volume и сети должны остаться прежними. При неготовности возвращает старый webroot и Caddy; DB/witness не меняются. Закрытый receipt сохраняется в `updates/web-<source>/receipt.json`; повтор поверх существующего release требует проверки состояния. Готовы проверки успешного переключения, отказа readiness с возвратом и изменённого Compose до переключения.

Автообновление видимого кабинета каждые 30 секунд и при возврате на вкладку включено из source `3c327e5f4e19`. Публичный SHA256 `account.js` совпал с manifest, ответ `200/no-store`. API и остальные контейнеры, Caddyfile/env/image/SSL volume/сети сохранились, что зафиксировано receipt. Новая Windows-служба автоматически синхронизирует аккаунт после входа; для ранее установленных клиентов требуется новая поставка, сервер сам их бинарные файлы не меняет.
