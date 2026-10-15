# Передача: запуск кабинета на desk.funti.cc — 2026-10-15

Продолжение [исходной передачи](2026-10-13-handoff-account.md). Работа остановлена по просьбе владельца для перехода в новый контекст. После этой просьбы серверы не изменялись. Публичный запуск кабинета и настоящая E2E-приёмка пока не завершены.

Актуальное продолжение: [публичный кабинет, SMTP/DNS и реальные входы 2026-10-15](2026-10-15-account-deploy-continuation.md). Состояние ниже сохранено исторически. По последующему решению владельца SMTP/HELO и требуемый PTR используют **desk.funti.cc**; `core.funti.cc` остаётся системным hostname. Закрытый доступ восстановлен, подробные текущие результаты и остаток приёмки находятся в новом отчёте.

## Цель и указания владельца

Продолжить основной запуск первого этапа на **desk.funti.cc / Core**: web, account API, собственный SMTP и resolver hbbs. Владелец уже поручил продолжать развёртывание. Повторно спрашивать общее разрешение не нужно.

Владелец отдельно остановил уход в настройку DE: основной сервис должен быть на Core. DE используется для доступа к Core и как предусмотренный ADR-011 независимый witness. Его настройка нужна как зависимость основного сервиса; не переносить туда кабинет/API/SMTP и не превращать это в отдельную задачу.

Тестовый почтовый ящик и публичный age recipient **уже получены** и сохранены отдельно от Git, см. «Доступ». Не просить их повторно. Применение DNS пока не подтверждено: сначала проверить фактические записи.

Прочитать `AGENTS.md`, `docs/ACCOUNT_DEPLOYMENT.md`, `docs/ACCOUNT_RECOVERY.md`, ADR-009/010/011. Не обходить witness или fail closed ради запуска. Не менять VPN, PostgreSQL, Valkey и посторонние блоки Caddy. Сохранить данные и ключи действующего hbbs/hbbr. Не публиковать личные имена, тестовую почту, токены, приватные ключи, подписанные URL артефактов и production environment.

## Код и проверенная поставка

Основная реализация объединена в **PR #43**, merge commit `a42f05faa3c4e277f4eef7e05fa2bac9abbc4387`. Последующие проверки этого commit успешны. Merge сам по себе не разворачивал серверы.

Рабочая ветка **`codex/account-deploy-desk`**, каталог `/workspace/FuntiDesk-account-deploy`, основание main `0a8895cce7f385dc5a038ff660ed45f49e482f41`.

| Commit | Содержание |
| --- | --- |
| `691a9c2d746d2202a5fb7cf30a44f89b1182ec31` | Закреплённая поставка и `prepare-desk.py` |
| `f0c7457845584383ebf2007591efebfa70bb56ff` | Проверка OCI/classic image IDs, retag обоих manifests, новый resolver release |
| `bc1806e74a3a8ebe96ca8b169d84221a821aa374` | `stage-desk.py`, проверенный webroot и полный кандидат Caddy |

Для `bc1806e7` завершились успешно:

- [FuntiDesk CI 38647877950](https://github.com/michailr1/FuntiDesk/actions/runs/38647877950).
- [Account checks 38647877961](https://github.com/michailr1/FuntiDesk/actions/runs/38647877961).

`scripts/account/activate-desk.py` сохранён при передаче как **черновик**. Он не запускался на Core и ещё не прошёл ревью. Перед использованием проверить условия отката, checksum исходного backup и готовность HTTP после пересоздания Caddy. Диагностический HTTP-клиент в frontend-сети ещё не проверен на работающем API. Наличие файла не означает готовую процедуру активации.

Параметры поставки закреплены в `infra/funtidesk-account/account-release.json`:

| Параметр | Значение |
| --- | --- |
| Source | `a42f05faa3c4e277f4eef7e05fa2bac9abbc4387` |
| Account checks run / artifact | `38622971931` / `11922857734` |
| ZIP SHA256 | `97ef3b8ddda52dea2c1ffcf97c934ce366fb0032eac129a7d884257ff4419b50` |
| Docker archive SHA256 | `72b7dda8754e8e0ee14f43c3304f1c3eb537d4e4cf68013ae02eed426c22d332` |
| hbbs SHA256 | `3c3fc2edc4ef212c68105d225475ea9f503f2d9a0de41976279fb233ff655c3b` |
| hbbr SHA256 | `a1129fcf61ca2baad109c72b497516d27816a828bed9aa389c1a3c15b92556c5` |

На Core Docker возвращает OCI manifest IDs; это предусмотрено release manifest. Не подменять их classic config IDs без проверки. Архив содержит Docker `manifest.json` и OCI `index.json`; исправленный prepare меняет оба.

Локально проверенный ZIP и распакованные файлы: `/workspace/scratch/account-main-a42/`. Не брать более старые пакеты из соседних каталогов scratch. Повторно скачивать пакет на Core сейчас не нужно.

## Core: последнее подтверждённое состояние

Это сохранённый результат предыдущей работы. В новом контексте сначала сверить его чтением.

SSH `root@desk.funti.cc` работает **с DE**, с проверкой host key. Фактический hostname — `core.funti.cc`, IPv4 `173.249.195.36`. Прямой SSH из managed workspace ранее не работал.

### Подготовка account

- `/opt/funtidesk-account-source` — чистый sparse checkout `bc1806e74a3a8ebe96ca8b169d84221a821aa374`.
- `/opt/funtidesk-account` подготовлен успешно; маркер `PREPARED` относится к `f0c74578`. Три проверенных образа загружены с тегами исходного SHA.
- Account key, machine witness key и DKIM private key **уже созданы на Core**. Не пересоздавать их. `account.env` содержит существующий namespace и image IDs; не создавать другой namespace поверх него.
- Data UID/GID `10001`, mode `0700`; account/witness keys `0400` для UID `10001`; DKIM private key root `0600`; secrets directory root `0700`.
- `identity/` подготовлен для группы `10001`, сокета hbbs пока нет.
- `data/account.sqlite3` **ещё не создана**, API не запускался.
- Age recipient пришёл после подготовки; encrypted backup новых ключей **ещё не создан**.
- `/opt/funtidesk-account/dns-records.json` содержит публичные SPF/DKIM.
- Background prepare завершился успешно. Не повторять prepare: каталог и ключи уже существуют. Метаданные процесса — `/run/funtidesk-account-prepare.json` и `.log`.

### Точная остановка: SMTP

Созданы приватные `mail` и `witness-relay`:

```sh
docker compose -p funtidesk-account \
  --env-file /opt/funtidesk-account/account.env \
  -f /opt/funtidesk-account-source/infra/funtidesk-account/compose.yaml \
  up -d mail witness-relay
```

Публичных PortBindings нет. Начальный inspect показал running, но **устойчивая готовность SMTP не подтверждена**. TCP с хоста к `172.31.250.2:2525` завершился OSError; попытка диагностики из той же сети дала exit 1 без сохранённого stderr. Причина пока неизвестна.

Последний MCP-запрос запрашивал status/ExitCode/RestartCount, IP и отфильтрованные error-логи этих контейнеров. Его результат не сохранился: старый локальный процесс MCP уже отсутствует. **Начать с нового read-only запроса `docker ps -a`, inspect и безопасных логов**, не считать SMTP работающим. Не выводить environment, письма, адреса и коды.

Закрытые сети: `172.31.250.0/29` SMTP, `172.31.251.0/29` frontend, `172.31.252.0/29` witness relay. До создания пересечения с маршрутами и Docker nets Core были проверены.

### Сайт и Caddy: staged, не включены

Подготовлен immutable webroot:

`/opt/funtidesk-web/releases/a42f05faa3c4e277f4eef7e05fa2bac9abbc4387-account`

Проверены manifest и все 18 публичных файлов. Полный кандидат Caddyfile прошёл validation действующим Caddy. Закрытый `/opt/funtidesk-account/integration/` содержит:

- `Caddyfile.before`, `Caddyfile.candidate`;
- `caddy-account.override.yaml`, `hbbs-identity.override.yaml`;
- `stage.json` с хешами, прежним webroot и образом Caddy.

**Публичный сайт ещё не переключён.** `current` по-прежнему указывает на `/opt/funtidesk-web/releases/0344118bcc88a6185b81f701ba9e43d7e8705495-artifact`.

Действующий Caddy: project/service `caddy`, `/opt/remnawave/caddy/docker-compose.yml`, Caddyfile в том же каталоге. Исходный container ID `53359f2b2986`; image `sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b`.

Сохранить исходный SSL volume, remnawave-network и остальные блоки. При применении добавить frontend собственным override и пересоздать только Caddy с исходным Compose; не запускать весь VPN stack заново. `stage-desk.py` повторно вслепую не запускать: артефакты уже существуют.

### Действующий hbbs/hbbr

Ещё работают на `funtidesk-server:funtidesk-server-78e50da1aa01`, без account resolver socket. Данные — `/opt/funtidesk/data`, env — `/opt/funtidesk/server.env`. Старый `/opt/funtidesk/repo` был clean на `63a9ec90d96903e6c2efe2c8c7f346826d4e09d7`; не сбрасывать/удалять его вслепую.

Перед обновлением сохранить согласованную encrypted копию SQLite и server identity. Применять pinned release `a42f05fa` по процедуре репозитория с `hbbs-identity.override.yaml`, socket `/run/funtidesk-identity/hbbs.sock` и GID `10001`. Проверить прежнюю server identity после обновления. Новый hbbr имеет тот же binary digest; изменённый hbbs нужен для resolver.

## Независимый witness на DE

Это зависимость безопасности ADR-011; основной account остаётся на Core. Не отключать freshness/HMAC и не помещать оба состояния на Core.

От прошлой работы остались TLS mirror и активный hourly timer `funtidesk-account-witness-tls.timer` на DE. Сертификат действующего Caddy для `de.funti.cc` был проверен, срок до 2026-12-03. Собственный mirror: `/opt/funtidesk-account-witness/secrets/tls`.

**Сам witness ещё не установлен**: данные/namespace/HMAC key не инициализированы, постоянных контейнеров нет. Порт `8447` выбран вместо занятого `8446`; снова проверить свободность и сети.

TLS-ветка `codex/account-witness-tls`, commit `e3a98f77`, PR #48 не merged. На DE TLS source checkout `/opt/funtidesk-account-witness-tls-source` закреплён на `6316cd27`. Не продолжать отдельную переработку TLS. Использовать проверенную конфигурацию с loopback admin `127.0.0.1:2019`, необходимую установленному sync script.

Передать по защищённому каналу только machine witness key, тот же namespace и проверенный API image `a42f05fa`. Account key остаётся на Core и в encrypted backup владельца. Не выводить ключи при копировании. На DE было около 1,5 ГБ свободно: не передавать туда весь архив API/mail/server и не удалять чужие Docker resources. UID witness `10002`; сети `172.31.253.0/29`, `172.31.254.0/29` требуют повторной проверки пересечений.

## DNS и почта

DNS — Cloudflare; готового DNS credential или инструмента в текущем контексте не было. Владельцу уже переданы точные записи; применение не подтверждено. Проверить DNS перед новым вопросом.

SPF заменить **в существующей единственной TXT**, сохранив отправителей:

```text
v=spf1 mx a:funti.cc ip4:172.245.108.154 ip4:173.249.195.36 include:sendinblue.com ~all
```

DKIM TXT: `funtidesk202610._domainkey.funti.cc`; полное публичное значение брать из `/opt/funtidesk-account/dns-records.json` на Core. Не генерировать другой ключ. DMARC уже был `v=DMARC1; p=none`, MX не менять. PTR содержит `core.funti.cc`, forward имени ведёт на Core. Исходящий SMTP/25 ранее проверен.

Тестовый mailbox уже задан владельцем; отправка проверочного login code разрешена. Реальная доставка и вход с этим письмом ещё не проверены. Код действует 5 минут, сессия 30 дней; автоматическое удаление аккаунтов сейчас не включать.

## Доступ и локальное продолжение

Рабочий endpoint — **`https://de.funti.cc/mcp`** на 443. Старый `:8445/mcp` возвращал 503. Прямой MCP с bearer пользователя работал: protocol `2025-03-26`, server `hermes-vps`, tools `health`, `run_shell`, `ask_hermes`. Shell tool принимает `command`, `workdir`, `timeout`. Долгие операции запускать с безопасным background log и опросом состояния, не держать HTTP дольше timeout.

Клиент без встроенных секретов — `/workspace/scratch/funti-de-mcp-client.py`. Получает bearer первой строкой stdin, затем JSON lines. Старый session ID `79318` **недействителен**: создать новый процесс. Для Core использовать SSH с `BatchMode=yes`, `StrictHostKeyChecking=yes`; host key и authentication уже есть на DE. Проверку ключа хоста не отключать.

Параметры продолжения сохранены **вне Git**: `/workspace/.private/funtidesk-handoff/continuation.json` (`0600`, каталог `0700`). Там ранее предоставленные MCP bearer, тестовый mailbox и публичный age recipient. Не печатать файл целиком: читать нужные поля внутри процесса. Приватной age identity у исполнителя нет и не нужно. В том же каталоге есть копии MCP client и activation draft.

Текущий разрешённый тестовый Gmail для самостоятельного чтения писем сохранён отдельно в `/workspace/.private/funtidesk-handoff/acceptance-mailbox.json` (`0600`, поле `email`); он выбран владельцем позднее исходного mailbox в `continuation.json`. Адрес не публиковать и не запрашивать повторно.

При переходе на другой workspace локальные файлы сами не переедут: перенести закрытый каталог безопасно, отдельно от Git. Публичная ссылка на handoff не переносит credentials.

## Порядок продолжения

1. Сверить Core чтением; диагностировать private SMTP. Сохранить hardening, обязательные DKIM и verified outbound TLS. Проверять готовность из Docker сети, не публиковать SMTP наружу.
2. Создать на Core encrypted backup account/witness/DKIM keys и metadata на уже присланный age recipient; plaintext temporary удалить. Сохранить независимую копию ciphertext и проверить digest. Отдельно защитить server identity/SQLite до обновления hbbs.
3. Подготовить минимальный независимый witness, проверить подписанный свежий head. Сохранить уже существующие Core keys/namespace.
4. Обновить hbbs до resolver release с сохранением данных/ключа; проверить socket и доступ API UID/GID.
5. Явно инициализировать только новую account DB после backup и fresh witness, запустить API. Проверить health, unauthenticated session `401`, Origin/CSRF и fail closed. Не использовать restore для обхода инициализации.
6. Проверить реальные DNS, закончить ревью activation draft и применить desk Caddy/webroot с проверенным rollback. Проверить HTTPS и сохранность остальных сервисов.
7. Проверить письмо на уже предоставленном ящике, браузерный вход и настоящие Windows-клиенты. CI/локальный Chromium сами по себе не закрывают M3.
8. Записать фактическую приёмку, обновить ROADMAP/PR. Пока это handoff незавершённого развёртывания, не объявлять кабинет запущенным.

На время передачи нет известной незавершённой команды deployment. Повторная диагностика SMTP должна быть новым read-only запросом. После просьбы о handoff новых серверных изменений не выполнялось.
