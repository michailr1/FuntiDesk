# Продолжение запуска кабинета — 2026-10-15

Продолжение [хендофа](2026-10-15-handoff-account-deploy.md), [PR #50](https://github.com/michailr1/FuntiDesk/pull/50). Приватные сервисы включены; публичный сайт пока не переключён. Реальная M3-приёмка не завершена.

## Размещение и сохранность

Закрытый архив владельца восстановлен в `/workspace/.private/funtidesk-handoff/`: каталог `0700`, файлы `0600`, вне Git. Доступ Core через DE с проверкой SSH host key подтверждён. Действующий VPS имеет системное имя `core.funti.cc`; кабинет и SMTP используют `desk.funti.cc`, IPv4 `173.249.195.36`. Выбор SMTP имени `desk.funti.cc` подтверждён владельцем 2026-10-15; системное имя менять не требуется.

На Core остаются web/API/SMTP, resolver hbbs и основные данные. На DE установлены только независимый witness ADR-011 и зашифрованные копии. Account key и основная база на DE не передавались. VPN/Postgres/Valkey и посторонние Caddy-блоки не изменялись. Существующие account/witness/DKIM keys, namespace и server identity сохранены.

## Закреплённые исходники

- API/mail packages и staged web: `a42f05faa3c4e277f4eef7e05fa2bac9abbc4387`, успешный run `38622971931`, artifact `11922857734`; ZIP/внутренние checksums/image IDs/source labels сверены с `account-release.json`.
- Deploy checkout Core: `/opt/funtidesk-account-source`, чистый `aa2f076ae758fa3adc5d278881df177b52f04a53` на момент применения SMTP. Это source инструментов и bootstrap, не новая сборка API.
- SMTP package image OCI: `sha256:6797debf4de8eb62776467b89cfbc1e5d1a41e14338ec68f52566d1ee9af3af7`. Новый executable bootstrap монтируется read-only из deploy checkout, SHA256 `43db098df9f0f64ffbb555c7c1b767231dff8e2ada8026b32b715e8a4b8d9189`. Обновлённая конфигурация не приписывается содержимому старого image.
- Штатный server release: `funtidesk-server-a42f05faa3c4`, image `sha256:b83771360e408b254629a6435dffceeb7ea2dcb277c59b90771a85114ddec13e`. Release binaries и checksums проверены, runtime image собран штатным helper.
- DE TLS source: `/opt/funtidesk-account-witness-tls-source`, `6316cd2705d1e5dc696425ac26bea64438a2f14d`. Сохранён loopback admin `127.0.0.1:2019`, необходимый уже установленному TLS sync. Переработка TLS PR #48 не продолжалась.

## DNS и настоящая почта

В Cloudflare изменена существующая единственная SPF, с прежними record ID/TTL и отправителями:

```text
v=spf1 mx a:funti.cc ip4:172.245.108.154 ip4:173.249.195.36 include:sendinblue.com ~all
```

Добавлен TXT `funtidesk202610._domainkey.funti.cc` с публичным значением **существующего** Core key. Cloudflare API и два независимых публичных резолвера подтвердили обе записи. MX и прочие TXT не менялись. DMARC остаётся `v=DMARC1; p=none`.

Фактический исходящий IP Core подтверждён как `173.249.195.36`; A `desk.funti.cc` возвращает тот же IP. Владелец сообщил о применении PTR → `desk.funti.cc`. На последней проверке публичные резолверы и оба авторитетных NS провайдера ещё возвращали NXDOMAIN: распространение записи пока не доказано. Старое указание PTR → `core.funti.cc` больше не применяется.

Реальный native HTTP вход с полученным владельцем письмом прошёл: verify `200`, authenticated session `200`; письмо оказалось **в спаме**. Затем владелец предоставил доступный исполнителю тестовый Gmail. Найдено только соответствующее тестовое письмо; заголовки Gmail подтвердили **SPF=PASS, DKIM=PASS, DMARC=PASS**, присутствует DKIM signature, метка `SPAM`, метки `INBOX` нет. Код прочитан исполнителем и передан браузеру без вывода или добавления в Git. Доставка во входящие остаётся незакрытым критерием; причину спама нельзя свести только к подлинности письма.

На настоящем Chromium выполнен вход в действующий приватный API с этим письмом: verify `200`, защищённая HttpOnly/Secure/SameSite=Strict cookie, reload, отсутствие session token в JavaScript/storage, Origin/CSRF на POST, logout `204`, прежняя cookie получает `401`, page errors отсутствуют. В этом тесте статические файлы того же `a42f05fa` подставлены browser route, API идёт через существующий защищённый management channel. **Публичный Caddy и его TLS/headers этим тестом не проверены**; после переключения нужна отдельная HTTPS-проверка.

## Две подтверждённые ошибки SMTP

1. Core mail аварийно завершался с категориями `permission denied`/`scan_dir_push`. Корень bind-очереди был root:root `0700`. Изменён **только корень** `/opt/funtidesk-account/mail-queue` на `0755`; закрытые подкаталоги сохранили `0700`. Перезапущен только mail. Исправлена подготовка новых каталогов; smoke проверяет настоящий bind mount под umask `077`.
2. Postfix использовал единственный адрес `inet_interfaces` как source исходящего SMTP. В mail netns соединение с MX на TCP/25 с kernel-selected source работало, с приватным listener source — timeout, с outbound source — работало. Установлен `smtp_bind_address=0.0.0.0`, что оставляет выбор source маршруту; приватный listener сохранён. SMTP hostname/HELO теперь `desk.funti.cc`.

Mail работает без опубликованных портов, RestartCount `0`; SMTP banner проверен из API netns. Сохранены hardening, обязательный DKIM (`tempfail`), outbound TLS `verify`, отсутствие адресов/кодов в logs. Ключи/env/namespace, API/relay/hbbs/hbbr и Caddy не пересоздавались при исправлении SMTP. Вторая регрессия использует настоящий Postfix transport и fake MX во второй изолированной сети; fixture отказывает до MAIL/DATA, наружу тесты письма не отправляют.

## Зашифрованные резервные копии

Созданы до включения API и обновления hbbs; production plaintext tar не создавался. Tar поступает прямо в age на уже предоставленный публичный recipient владельца. Server SQLite снят через Online Backup в RAM, с committed WAL и `integrity_check`; identity сверена до/после.

| Компонент | Файл на Core в `/opt/funtidesk-account/backups/` | SHA256 ciphertext |
| --- | --- | --- |
| Account/witness/DKIM keys и metadata | `funtidesk-account-secrets-20261015T041525Z.tar.gz.age` | `e3aa567ed30ef0b1996b188a4aa5b6b00ce567b48d817362cccfcbf61dd9f077` |
| Server identity/env/SQLite | `funtidesk-server-20261015T041743Z.tar.gz.age` | `36fb0212059cd3784da7e12666356a6525cbca4418ad2e6c94ec966f7d830ff1` |

Независимые ciphertext-копии с теми же именами находятся на DE в `/opt/funtidesk-account-witness/backups/`; digest совпал с Core. Каталоги `0700`, файлы/receipts `0600`. Приватная age identity не передавалась исполнителю; production расшифрование остаётся проверкой владельца. Account-secrets archive не содержит позднее созданную account DB; актуальные зашифрованные снимки этой базы принимает отдельный witness.

## Witness, hbbs и API

На DE запущен отдельный Compose project `funtidesk-account-witness`: UID `10002`, machine witness key и прежний namespace, изолированные data/networks, Caddy публикует только TLS `8447`. Перед первым initialize доказан подписанный свежий Head `revision=0`, `event_highwater=0` по прямому TLS и через relay. Выполнен `witness-init` ровно один раз. Неверный MAC получает `401`, чужой путь — `404`. Контейнеры работают без restart; установленный TLS sync service успешно выполнен после запуска контейнеров, hourly timer активен.

hbbs/hbbr обновлены до закреплённого server release штатным build helper с сохранением `/opt/funtidesk/data`, ключей, портов и сети. Штатный verify прошёл. Resolver socket `0660`, GID `10001`; настоящий процесс от API UID/GID `10001:10001` успешно получил корректный ответ на неизвестный ID. Старый `/opt/funtidesk/repo` оставлен чистым и неизменённым. Действующий Compose теперь берётся из нового source с identity override: [точная команда](../ACCOUNT_DEPLOYMENT.md#действующие-серверные-конфигурации).

Новая account DB явно инициализирована ровно один раз после backups и fresh witness; markers сохранены. API работает от `10001:10001`, без публичных портов. Проверены private health `200`, unauthenticated session `401`, неверные Host/Origin/CSRF `403`, Secure/HttpOnly/SameSite=Strict cookie. Запуск без witness отказал; relay восстановлен.

После реального входа witness продвинулся до revision `2`, highwater `1`. При остановленном только relay authenticated logout вернул `503`; после восстановления связи отложенный отзыв был подтверждён, прежняя сессия получила `401`. Нормальный перезапуск API сохранил этот отзыв; свежий подписанный Head по обоим путям — revision `3`, highwater `1`. Не откатывать эту операцию ради повторного использования тестовой сессии. Это реальная проверка fail closed и завершения отзыва; тесты удаления устройств/ACK на Windows ещё не выполнены. После последующего Chromium входа/выхода в другом разрешённом тестовом ящике свежий Head по обоим путям — revision `6`, highwater `2`; очередь mail пуста, API/mail/relay работают без restart и опубликованных портов. Безопасные receipts находятся в закрытом `integration`, включая `acceptance-runtime.json` и `acceptance-browser-gmail.json`; stdout/stderr проверены без вывода сырых logs.

## Caddy и проверки

Старый webroot `0344118bcc88a6185b81f701ba9e43d7e8705495-artifact` ещё действует; новый `a42f05faa3c4e277f4eef7e05fa2bac9abbc4387-account` staged. Публичные `/account/` и API пока `404`, основной сайт `200`. Caddy не пересоздавался этим продолжением.

`activate-desk.py` проверяет checksum backup/candidate, исходный Compose hash/image/mounts/физические сети, DB/socket/private API и SPF/DKIM. Проверена реальная подготовительная фаза на Core, без переключения. Исправлена эквивалентность Compose `null`/`{}` только для пустого network attachment; непустые настройки сравниваются полностью. Откат разделён по фазам, HTTPS готовность и восстановление старого сайта проверяются с ограниченными повторами.

Прошли 32 unit tests активации, 9 реальных age round-trip/WAL/permissions/tampering tests backup helper, 15 witness probe tests. На закреплённых images прошли Compose/Caddy validation и полный SMTP smoke: настоящий код, независимое encrypted state, CLI restore инвалидирует старую сессию, private HTTP client, outbound source/desk HELO, отказ постороннему sender и без DKIM, log privacy. Локальный restore использовал только тестовые ключи/данные, не production. Для `aa2f076a` завершились успешно FuntiDesk CI run `38685552493` и Account checks run `38685552574`, включая deployment tools и infra smoke.

## Остаток приёмки

1. Доказать PTR `173.249.195.36` → `desk.funti.cc` на авторитетных NS и публичных резолверах; повторить реальную доставку во входящие. SPF/DKIM/DMARC на тестовом Gmail уже PASS.
2. После выполнения почтовых условий повторить актуальные private API/witness проверки и безопасно включить staged Caddy/webroot штатным helper. Browser login с реальным письмом уже проверен на приватном API; публичный путь ещё не проверен.
3. Проверить публичные HTTPS/API/headers/cookie/CSRF и доступные отказные сценарии после переключения. Основной account DB/witness не откатывать вместе с интерфейсом.
4. Провести приёмку двух настоящих Windows-клиентов: bind, family, lost device/removal/ACK, restart/offline/replay, сетевой захват. Зафиксировать точные клиентские SHA и обновить статус; успешная сборка и API-проверки M3 не закрывают.

Повторные `prepare`, `witness-init`, `account initialize` запрещены для уже созданного состояния. Новые закрытые keys/namespace не создавать; ожидающий отзыв не обходить восстановлением старой DB. Merge и завершённый production launch пока не заявляются.
