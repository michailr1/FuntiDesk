# Кабинет: проверка проекта поставки

Эксплуатационные сведения об общей инфраструктуре и других узлах перенесены в закрытый архив владельца; здесь сохранены доступные сведения о проверках продукта.

Дата: 2026-10-14. Статус: локально проверенный draft; не production и не E2E-приёмка.

## Основание конфигурации


Добавлены отдельные account/SMTP-сети, proposed desk-блок и Caddy override, hbbs socket override, Dockerfiles и проверки. У новых контейнеров нет публичных портов. Account не получает сеть/данные VPN, Postgres, Valkey или приватный ключ hbbs. Единственный новый участник frontend со стороны существующего стека — Caddy; прежние mounts и сеть сохранены.

## Фактические проверки

- `check-config.py`: Compose config корректен; слияние Caddy override на минимальном fixture проверенных существующих полей сохраняет mounts и сеть. Proposed desk-блок прошёл `caddy adapt --validate` в Caddy с digest `sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b`, без сети. Позднее через восстановленный MCP проверены полный кандидат production Caddyfile и слияние настоящего Compose, без применения; hashes и точный патч — в [общем отчёте](2026-10-14-account-integration-check.md).
- API image собран из musl-артефакта успешного [Account checks, run 38479485058](https://github.com/michailr1/FuntiDesk/actions/runs/38479485058), исходный commit `9ae19e117335792bff387208f910a0df71f02a1d`. ZIP SHA-256: `ecbe2874c0e9264a3711f2eb24165e6bfcffe335518bf01350f99e03a7956f1b`; внутренний `SHA256SUMS` проверен. Image ID: `sha256:23daa5568b1ff812fb3046b90ab85fe9d184fc1ef6b1670dfaad1abd18d03b67`.
- Mail image локально собран из закреплённого Debian digest и версий Postfix/OpenDKIM. Под ограничениями readonly/capabilities исправлены startup-права `/var/lib/postfix`, tmpfs-путь OpenDKIM config и allowlist для `/dev/null`-лога. Это временный проверочный образ, не production pin.
- `smoke-mail.py` прошёл: настоящий account API запросил письмо, собственный Postfix/OpenDKIM поставил его в изолированную очередь с `d=funti.cc`, selector `funtidesk202610`; код из письма открыл native session. Чужой envelope sender отклонён; после остановки OpenDKIM отправка получила временный отказ. Адрес, код, challenge/login context и token отсутствуют в stdout/stderr контейнеров. Открыт только private SMTP interface. Тестовые ключи/тома удаляются в `finally`; исходящая доставка заблокирована сетью и deferred transport.
- Shell/Python syntax, YAML parsing и `git diff --check` прошли. Новый CI job повторяет сборку образов и эти проверки, затем сохраняет archive/provenance с SHA-256. Финальный code commit `3697e96a692aef33228aae6e9f096f3dd4061d52` прошёл [Account checks, run 38521487771](https://github.com/michailr1/FuntiDesk/actions/runs/38521487771): API/registry и все проверки SMTP/Caddy, включая читаемый русский UTF-8 текст; также успешен [FuntiDesk CI](https://github.com/michailr1/FuntiDesk/actions/runs/38521487733). Artifact `funtidesk-account-infra-3697e96a692aef33228aae6e9f096f3dd4061d52` — 65 790 628 байт, ZIP digest `sha256:a41d0557aeaca4033b64b56d8feb72fe3c6157671ab9b230ceb23a9fcf31a8de`. Он содержит оба checked image, source/image/package manifests и SHA256SUMS. Права workflow только `contents: read`.

Первый CI выявил ошибку harness: обрезание заголовков до `From` теряло `Content-Transfer-Encoding`, если библиотека ставила его раньше. Разбор сохраняет все MIME headers и исключает Postfix wrapper; порядок воспроизведён отдельно, повторный smoke прошёл. Дополнительно API явно объявляет UTF-8 для русского тела; до исправления декодирование кириллицы в настоящем письме не проходило. Эти исправления включены в указанный финальный run.


## Границы и дальнейшая приёмка

Новые конфиги не применялись; внешний SMTP и DNS не менялись, письма реальным получателям не отправлялись. DNS уже содержит SPF и DMARC: подготовлена замена одной SPF с сохранением существующих отправителей; публичный DKIM создаётся на сервере после разрешения, не заменяется тестовым ключом.

Прототип независимой зашифрованной копии и контроля последней отметки реализован по проекту ADR-011; [проверки восстановления](2026-10-14-account-recovery-check.md) проходят локально. На рабочих серверах его пока нет. Restore не объявляет сервис принятым: утверждение схемы, сроки хранения/удаление аккаунта и реальная приёмка нужны до запуска.

Windows build/storage и реальные службы/portable, два компьютера и браузер, offline/restart/replay, доставка во входящие Gmail/Яндекса/Mail.ru и сетевой захват остаются отдельными критериями. Merge, release и production выполняются после согласия владельца по handoff.


## Дополнение: независимое состояние и CLI restore

На статическом API binary из успешного [Account checks 38589046761](https://github.com/michailr1/FuntiDesk/actions/runs/38589046761), commit `ffd270b85e8e6761c0a54219c6e3d2fce70b50e1`, локально собран `funtidesk-account:recovery-ffd` (`sha256:876e67bae1d189923b3a008639608b2c314ca6b1bf137664975b5ce367115c4a`). ZIP артефакта 11906747358 проверен по `df762014202ccd0bf08b73a6b49bf856d991bd788d467a522733d7400a31679b`; manifest binary совпал. Текст AGPL для образа взят из исходного commit.

Обновлённый smoke запустил отдельный witness в изолированной Docker-сети и явно инициализировал обе базы. Настоящий API выдал почтовый код через Postfix/OpenDKIM и открыл нативную сессию; затем CLI `restore` восстановила последнюю зашифрованную базу в новый путь (`event_highwater=1`). Перезапущенный API отклонил старый токен с HTTP 401. Sender/DKIM refusal и отсутствие секретов в журналах также прошли. Все временные контейнеры/тома/сеть удалены.


## Проверка настоящего HTTPS witness


При проверке исправлены реальные дефекты проекта: на исключительно internal-сети Docker не публиковал Caddy port; официальный Caddy binary с file capability не исполнялся при полном cap_drop; унаследованный Docker HTTP proxy ломал внутренний запрос. Добавлены отдельная ingress-сеть, ровно NET_BIND_SERVICE для Caddy и NO_PROXY для адреса witness. Сам witness остаётся без capabilities и выходной сети. Секреты/тома данных переходнику не передаются.


CI теперь также собирает настоящие musl hbbs/hbbr с приватным resolver, пакует их собственный образ с AGPL/source revision вместе с account/mail и проверяет SHA256SUMS. Никакой release/deploy этим workflow не выполняется.
