# Поставка кабинета: проект конфигурации

Статус: draft для проверки. Это не команда развёртывания. На рабочем сервере ничего не менялось; merge, релиз и изменения production требуют согласия владельца по handoff и AGENTS. До запуска обязательны восстановление отзывов и E2E-приёмка, описанные ниже.

## Проверенный текущий сервер

2026-10-13 агент Windows миниПК через подключённый плагин `mypc windows` выполнил read-only проверку:

- Caddy — Compose-проект/service `caddy`, `/opt/remnawave/caddy/docker-compose.yml`, bridge `remnawave-network`, subnet `172.18.0.0/16`. Это не host network, поэтому `reverse_proxy 127.0.0.1:21800` из Caddy не работает с контейнером аккаунта.
- Caddyfile: `/opt/remnawave/caddy/Caddyfile` → `/etc/caddy/Caddyfile:ro`; webroot: `/opt/funtidesk-web/current` → `/usr/share/caddy:ro`; сертификаты в отдельном volume `caddy-ssl-data`.
- `current` указывает на каталог `/opt/funtidesk-web/releases/0344118bcc88a6185b81f701ba9e43d7e8705495-artifact`. Это статический каталог, не Git checkout. Public web manifest ранее совпал с закреплённым исходником.
- Account/SMTP/DKIM контейнеров пока нет; hbbs/hbbr используют `funtidesk-server:funtidesk-server-78e50da1aa01`. Этот старый образ не заявляется как поддерживающий новый resolver.
- Кандидаты `172.31.250.0/29` и `172.31.251.0/29` не пересекаются с проверенными Docker subnet/host routes. Перед изменением сети проверку повторяют.
- SSH `desk.funti.cc:22` с миниПК доступен с существующей аутентификацией. Из облачной среды был `Connection refused`; это не доказательство отказа SSH сервера.

## Что предлагается

`compose.yaml` запускает account в двух собственных внутренних сетях: frontend и SMTP. Только mail имеет отдельную выходную сеть. Account не присоединяется к VPN/Postgres/Valkey-сети и не получает их volumes. Публичных портов у новых контейнеров нет. API работает от UID/GID `10001`, без capabilities, с ограничениями памяти/процессов; ключ HMAC доступен только ему.

`caddy-account.override.yaml` добавляет только Caddy к новой frontend-сети и сохраняет его прежнюю `remnawave-network`. Статический адрес Caddy `172.31.251.4` разрешён API как единственный доверенный proxy. `Caddyfile.desk.proposed` заменяет **только** существующий блок `desk.funti.cc`: API-prefix идёт в account без HTML-fallback; Caddy перезаписывает адрес клиента; `/account/` получает no-store и CSP; прежний сайт продолжает отдаваться тем же webroot. Остальные домены и SSL volume не изменяются.

`hbbs-identity.override.yaml` добавляет hbbs отдельный каталог Unix socket и переменные resolver. Account видит этот каталог read-only, без hbbs базы/приватного ключа. Нужен новый образ сервера из проверенного commit с resolver, а не текущий старый image. Контроль identity socket и ошибочного пути проверяется до включения маршрута.

Смена webroot symlink и добавление frontend-сети требуют согласованного recreate **только Caddy**, с исходным Compose и новым override; reload не меняет уже разрешённый bind mount. Перед этим сохраняют точные текущие конфиги и проверяют общий Caddyfile; нельзя заменять его целиком фрагментом desk. Откат возвращает прежние Caddyfile/Compose/webroot; уже поставленные удаления не откатываются.

## Артефакты и секреты

Account image содержит статический musl binary из успешного `Account checks` и текст AGPL из `client/LICENCE`, проверенные по SHA256SUMS и связанному commit/run. Dockerfile не включает исходники, mail credentials или hbbs данные; source URL и revision доступны в OCI labels. Build context создаётся вне репозитория из этого артефакта. Mail image фиксирует Debian digest; установленные версии Postfix/OpenDKIM и итоговый image digest сохраняют в manifest поставки. Пакетные лицензии Debian сохраняются внутри mail image.

Job `account-infra` того же workflow берёт binary из текущего run, проверяет его SHA-256, собирает оба образа и запускает проверки ниже. Артефакт `funtidesk-account-infra-<commit>` содержит Docker archive, source SHA, image IDs, версии пакетов и SHA256SUMS; ни ключей, ни писем в нём нет. Workflow имеет только `contents: read`, не публикует релиз и ничего не развёртывает. Images загружают только из выбранного успешного run, проверив manifest; пример `.env` заменяют конкретными проверенными image IDs/тегами.

Локально проверки повторяются с уже собранными образами:

```sh
python3 scripts/account/check-config.py
FUNTI_ACCOUNT_IMAGE=<проверенный-образ-API> \
FUNTI_ACCOUNT_MAIL_IMAGE=<проверенный-образ-SMTP> \
python3 scripts/account/smoke-mail.py
```

Первая команда проверяет Compose и слияние Caddy override на минимальном fixture проверенных полей, затем валидирует предлагаемый desk-блок в закреплённом Caddy без сети. Это не проверка полного production Caddyfile. Вторая создаёт только временные контейнеры/тома/внутреннюю сеть, тестовые HMAC/DKIM keys, запрашивает код у настоящего API, читает подписанное письмо из изолированной очереди и открывает native session. Она также проверяет отказ чужому sender и временный отказ после остановки DKIM, отсутствие секретов в stdout/stderr; SMTP наружу блокирован. Ресурсы удаляются в `finally`. Свободный test subnet по умолчанию `172.31.249.0/29` можно переопределить через `FUNTI_ACCOUNT_TEST_SUBNET`.

На сервере, только после разрешения:

- отдельный `/opt/funtidesk-account` с защищёнными каталогами data/secrets/mail-queue/identity;
- HMAC: случайные 32 байта в hex, владелец файла UID `10001`, права `0400`; папка data UID/GID `10001`, `0700`;
- identity directory: root, группа `10001`, проход для этой группы; socket `0660`;
- DKIM RSA 2048+ создаётся **на сервере**, selector `funtidesk202610`, домен `funti.cc`; private key `0600`, не выводится и не попадает в Git. Публичный TXT передаётся владельцу отдельно;
- `.env` с проверенными image/адресами, без секретных значений; секреты доступны только назначенному контейнеру. Пример `.env.example` не является production env.

Mailer принимает SMTP только на своей private-границе `172.31.250.2:2525` от account subnet, не слушает публичный 25 и не требует стороннего почтового API. Envelope sender — `no-reply@funti.cc`; DKIM обязателен, сбой milter отклоняет отправку временно. SMTP наружу требует проверенный TLS; очередь живёт не более 5 минут. Postfix/OpenDKIM не пишут адреса/коды в stdout/syslog; операторские проверки показывают только агрегированные количества. Доставку Gmail/Яндекса/Mail.ru это пока не доказывает.

## DNS для владельца

Read-only DNS-проверка 2026-10-13: `desk.funti.cc` и `core.funti.cc` разрешаются в `173.249.195.36`. У `funti.cc` **уже есть** SPF:

```text
v=spf1 mx a:funti.cc ip4:172.245.108.154 include:sendinblue.com ~all
```

Нужна замена этой единственной SPF TXT, сохраняющая существующих отправителей и добавляющая фактический IPv4 нашего SMTP. При подтверждённом исходящем `173.249.195.36` предлагаемое значение:

```text
v=spf1 mx a:funti.cc ip4:172.245.108.154 ip4:173.249.195.36 include:sendinblue.com ~all
```

Не создают вторую SPF запись и не удаляют существующих отправителей. MX не меняется: наш контейнер только отправляет. Перед изменением подтверждают исходящий IP, PTR и forward DNS `core.funti.cc` на текущем сервере.

DKIM: TXT `funtidesk202610._domainkey.funti.cc` со значением `v=DKIM1; k=rsa; p=<публичный ключ, созданный на сервере>`. Это место для **публичного** значения; dummy/test key в production DNS не используется.

DMARC уже установлен: `_dmarc.funti.cc`, `v=DMARC1; p=none`. Для тестовой приёмки его не нужно дублировать или менять. Повышение политики и адрес отчётов — отдельное решение после проверки всех существующих отправителей.

## Backup/restore и критерии запуска

Нельзя просто добавить account в прежний tar `data/`: SQLite snapshot должен быть согласован с WAL, HMAC/DKIM keys защищены, резервные копии зашифрованы для владельца. Старый снимок сессий/nonce/challenge не запускают: их инвалидируют до старта. Локальные family ledgers на компьютерах не заменяются серверным backup.

Кроме снимка нужен **независимый актуальный журнал отзывов и подтверждённая последняя отметка**. Восстановление старого account DB без последних отзывов оставляет выключенный потерянный компьютер доверенным на ещё не получивших событие источниках. Текущий API сохраняет события в своей SQLite; отдельный журнал и проверка последней отметки восстановления ещё не реализованы. Поэтому в этом draft **нет deploy/restore-скрипта, объявляющего сервис готовым к production**. Автоматический restore запрещён до реализации и проверки этой части; успешный запуск контейнера не меняет этот статус.

До включения: архитектурное ревью ADR-010; завершённые Windows build/storage checks; независимый журнал и восстановление, сроки хранения/удаление аккаунта; Caddy validation/headers/CSRF/private network; свой SMTP с SPF/DKIM/DMARC; реальная доставка во входящие; два Windows-клиента и браузер, restart/offline/replay и сетевой захват. Образ клиента и backend/website фиксируют по точным SHA. Merge, production и выпуск — последним шагом после согласия владельца.
