# Кабинет: проверка проекта поставки

Дата: 2026-10-14. Статус: локально проверенный draft; не production и не E2E-приёмка.

## Основание конфигурации

По указанию владельца через подключённый плагин `mypc windows` запрошен агент Windows миниПК. Он выполнил только чтение текущего Caddy Compose, mounts, Docker сетей и маршрутов на сервере. Runs: `run_2c1380baf9b8475396c585963e5debec`, `run_49a5b49277014cb59c63251588f2893e`. Проверенный блок `desk.funti.cc`, каталог сайта, bridge `remnawave-network` и свободные кандидаты subnet зафиксированы в [infra README](../../infra/funtidesk-account/README.md). SSH с миниПК доступен; отказ из облачной среды не означал остановку сервера.

Добавлены отдельные account/SMTP-сети, proposed desk-блок и Caddy override, hbbs socket override, Dockerfiles и проверки. У новых контейнеров нет публичных портов. Account не получает сеть/данные VPN, Postgres, Valkey или приватный ключ hbbs. Единственный новый участник frontend со стороны существующего стека — Caddy; прежние mounts и сеть сохранены.

## Фактические проверки

- `check-config.py`: Compose config корректен; слияние Caddy override на минимальном fixture проверенных существующих полей сохраняет mounts и сеть. Proposed desk-блок прошёл `caddy adapt --validate` в Caddy с digest `sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b`, без сети. Полный production Caddyfile ещё не проверялся.
- API image собран из musl-артефакта успешного [Account checks, run 38479485058](https://github.com/michailr1/FuntiDesk/actions/runs/38479485058), исходный commit `9ae19e117335792bff387208f910a0df71f02a1d`. ZIP SHA-256: `ecbe2874c0e9264a3711f2eb24165e6bfcffe335518bf01350f99e03a7956f1b`; внутренний `SHA256SUMS` проверен. Image ID: `sha256:23daa5568b1ff812fb3046b90ab85fe9d184fc1ef6b1670dfaad1abd18d03b67`.
- Mail image локально собран из закреплённого Debian digest и версий Postfix/OpenDKIM. Под ограничениями readonly/capabilities исправлены startup-права `/var/lib/postfix`, tmpfs-путь OpenDKIM config и allowlist для `/dev/null`-лога. Это временный проверочный образ, не production pin.
- `smoke-mail.py` прошёл: настоящий account API запросил письмо, собственный Postfix/OpenDKIM поставил его в изолированную очередь с `d=funti.cc`, selector `funtidesk202610`; код из письма открыл native session. Чужой envelope sender отклонён; после остановки OpenDKIM отправка получила временный отказ. Адрес, код, challenge/login context и token отсутствуют в stdout/stderr контейнеров. Открыт только private SMTP interface. Тестовые ключи/тома удаляются в `finally`; исходящая доставка заблокирована сетью и deferred transport.
- Shell/Python syntax, YAML parsing и `git diff --check` прошли. Новый CI job повторяет сборку образов и эти проверки, затем сохраняет archive/provenance с SHA-256. Финальный code commit `3697e96a692aef33228aae6e9f096f3dd4061d52` прошёл [Account checks, run 38521487771](https://github.com/michailr1/FuntiDesk/actions/runs/38521487771): API/registry и все проверки SMTP/Caddy, включая читаемый русский UTF-8 текст; также успешен [FuntiDesk CI](https://github.com/michailr1/FuntiDesk/actions/runs/38521487733). Artifact `funtidesk-account-infra-3697e96a692aef33228aae6e9f096f3dd4061d52` — 65 790 628 байт, ZIP digest `sha256:a41d0557aeaca4033b64b56d8feb72fe3c6157671ab9b230ceb23a9fcf31a8de`. Он содержит оба checked image, source/image/package manifests и SHA256SUMS. Права workflow только `contents: read`.

Первый CI выявил ошибку harness: обрезание заголовков до `From` теряло `Content-Transfer-Encoding`, если библиотека ставила его раньше. Разбор сохраняет все MIME headers и исключает Postfix wrapper; порядок воспроизведён отдельно, повторный smoke прошёл. Дополнительно API явно объявляет UTF-8 для русского тела; до исправления декодирование кириллицы в настоящем письме не проходило. Эти исправления включены в указанный финальный run.

По последующему указанию владельца попытка связи перенаправлена к harness на `de.funti.cc`. Проверенные стандартные HTTPS MCP/API endpoints возвращают 404, корень — Verification. МиниПК не нашёл настроенного доверенного канала к нему; задача не передана. Нужен точный endpoint/transport, запрос владельцу открыт. Это не влияет на результаты локальной проверки Caddy с ранее прочитанной конфигурацией.

## Границы и дальнейшая приёмка

Новые конфиги не применялись; внешний SMTP и DNS не менялись, письма реальным получателям не отправлялись. DNS уже содержит SPF и DMARC: подготовлена замена одной SPF с сохранением существующих отправителей; публичный DKIM создаётся на сервере после разрешения, не заменяется тестовым ключом.

Независимый актуальный журнал отзывов и контроль последней отметки восстановления пока отсутствуют. В SQLite события сохраняются, но старый backup не доказывает наличие более новых удалений. Поэтому deploy/restore, объявляющих сервис готовым, в этом draft нет. Эта реализация, сроки хранения/удаление аккаунта и архитектурное ревью нужны до запуска.

Windows build/storage и реальные службы/portable, два компьютера и браузер, offline/restart/replay, доставка во входящие Gmail/Яндекса/Mail.ru и сетевой захват остаются отдельными критериями. Merge, release и production выполняются после согласия владельца по handoff.
