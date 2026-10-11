# desk.funti.cc — deployment state

Дата проверки: 2026-10-11

## Production

- URL: `https://desk.funti.cc`
- Документированный release: `ea4528fa653a8f2a8af93ff3a35e07870a67b660`
- Документированный release path: `/opt/funtidesk-web/releases/ea4528fa653a8f2a8af93ff3a35e07870a67b660/`
- Host symlink: `/opt/funtidesk-web/current`
- Caddy config: `/opt/remnawave/caddy/Caddyfile`
- Effective Caddy root inside container: `/usr/share/caddy`

## Важное уточнение после read-only аудита

Текущая production-раздача **не подтверждает** ранее описанную схему `release directory -> /opt/funtidesk-web/current -> Caddy`.

Read-only проверка показала:

- в Caddy container нет mount для `/usr/share/caddy`;
- compose-монтажи Caddy содержат Caddyfile и TLS data, но не `/opt/funtidesk-web/current`;
- SHA-256 live `/usr/share/caddy/index.html` не совпадает с `web/index.html` документированного release `ea4528fa...`;
- CSS/JS/logo live webroot также отличаются от файлов документированного release;
- следовательно, переключение host symlink `/opt/funtidesk-web/current` само по себе не является подтверждённым способом обновить реально обслуживаемый сайт.

До выяснения serving path production не переключать по старой инструкции.

## Текущая web-ветка

Branch: `michailr/funtidesk-web`

Client-first redesign подготовлен в истории ветки:

- `7a793d930966c105d6ff847515121d9f2db3df06` — новый `index.html`, выровненный с Windows M3 UI;
- `817cbac41e51ba5509d7a800a34932b2bb3bb47e` — интерактивная логика и размещение runtime P2P/Relay в session toolbar;
- `8ba4dc1ce2a3abe8afc71f8af2403705e2e27238` — client-first правила в `web/README.md`.

Read-only/static checks для HEAD `8ba4dc1...`:

- HTML parser: PASS;
- page title: `FuntiDesk · Удалённый доступ для своих`;
- ссылки на `./styles.css` и `./app.js`: присутствуют;
- scan на личное имя: совпадений не найдено;
- `git diff --check`: PASS;
- JavaScript syntax check через Node.js: не выполнен — Node.js отсутствовал в среде проверки.

## Production health на момент аудита

- HTTP -> HTTPS: `308`;
- HTTPS: `200`;
- production content не изменялся;
- Caddy не reload/recreate;
- hbbs/hbbr, DNS, firewall и server identity не изменялись.

## Блокер деплоя

Перед публикацией новой версии нужно выбрать и проверить один из безопасных вариантов:

1. **Исправить serving-path архитектуру**: сделать `/opt/funtidesk-web/current` явным read-only mount для Caddy `/usr/share/caddy`, после backup и с проверенным rollback. Это требует изменения Compose/container lifecycle.
2. **File-only deploy в текущий container webroot**: сначала снять полный проверяемый backup именно live `/usr/share/caddy`, затем атомарно заменить содержимое и проверить rollback. Этот путь не использовать без отдельного подтверждения процедуры.

Предпочтительный долгосрочный вариант — №1: release directories + symlink действительно становятся источником файлов Caddy, а rollback сводится к переключению symlink и контролируемому recreate/reload.

## Rollback material, известный до аудита

- `/opt/funtidesk-web/backups/Caddyfile.pre-deploy`
- `/opt/funtidesk-web/backups/Caddyfile.before-site-block`
- `/opt/funtidesk-web/backups/default-webroot/`
- `/opt/funtidesk-web/backups/caddy-default-webroot.tar`

Эти материалы не подтверждены как точная копия текущего live `/usr/share/caddy`; перед будущим production change необходимо создать свежий backup live webroot и проверить его hash/content.

## Security note

Во время диагностического агентского запуска credential VPS попал во внутренний tool log. Значение здесь не приводится. Credential следует считать раскрытым и ротировать через согласованный безопасный процесс. Локальная очистка части логов была выполнена, но один занятый log-файл не удалось переписать, поэтому ротация обязательна.

## Статус

`FUNTIDESK_WEB_REDESIGN_READY=true`

`FUNTIDESK_WEB_DEPLOY_BLOCKED_SERVING_PATH=true`
