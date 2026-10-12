# Upstream baseline и политика синхронизации

## Baseline

FuntiDesk стартует со стабильных версий исходных проектов, зафиксированных на 2026-09-17:

- Client: `rustdesk/rustdesk`, tag `1.5.0`, commit `9d3ae7acd2d13e8ce9928ce827e86d13d0f17132` (слияние 2026-10-11; до этого — tag `1.4.9`, commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`).
- Server: `rustdesk/rustdesk-server`, tag `1.1.16`, commit `73523b31cfd25d77dee862e6fc9f5e1fb5e485ef`.
- Shared library: `rustdesk/hbb_common`, подключён в обоих проектах как git submodule `libs/hbb_common` и закреплён на разных коммитах:
  - для клиента — `229b904508364c8997aad0fb5af57effac859f60` (как в RustDesk 1.5.0; до 2026-10-11 — `7e1c392c62d39c364127307cd408421dd5f8cfb0`);
  - для сервера — `83419b6549636ee39dacef7776c473f5802e08d6`.

`hbb_common` — не вспомогательная зависимость: именно в нём находится `src/config.rs` с адресами rendezvous-серверов, публичным ключом и логикой выбора сервера, то есть один из ключевых участков нашего security-форка.

Мы сознательно не используем плавающий `master` как baseline.

## Структура репозитория

Архитектурное решение и обоснование структуры являются **авторитетными только в** `docs/ADR-001-repository-layout.md`. Здесь фиксируются текущие upstream pins и политика синхронизации, без дублирования ADR.

Кратко: product repository — монорепозиторий; client/server и две независимые копии `hbb_common` импортированы в дерево репозитория и не требуют внешних submodule для production build.

## Upstream remotes

Рекомендуемые локальные remotes:

```text
origin            -> github.com/michailr1/FuntiDesk
upstream-client   -> github.com/rustdesk/rustdesk
upstream-server   -> github.com/rustdesk/rustdesk-server
upstream-common   -> github.com/rustdesk/hbb_common
```

## Политика merge

1. FuntiDesk-специфичные изменения должны оставаться небольшими и изолированными.
2. Изменения протокола допускаются только при необходимости для задокументированной функции или security property.
3. Предпочтительны build-time configuration, branding modules и policy wrappers вместо инвазивных изменений сетевого/media core.
4. По умолчанию отслеживаются стабильные upstream-релизы, а не nightly/master.
5. Upstream security fixes проверяются оперативно и по возможности переносятся независимо от функциональных обновлений.
6. Любой upstream merge/rebase перед релизом должен пройти E2E-матрицу FuntiDesk.
7. Клиентская и серверная копии `hbb_common` обновляются независимо; запрещено синхронизировать их на один commit только ради эстетики структуры.
8. Новый pin `hbb_common` принимается вместе с соответствующим upstream release либо отдельным обоснованным security backport.

## Области ожидаемого расхождения

Найденные при ревью конкретные точки расхождения с указанием файлов перечислены в `docs/UPSTREAM_REVIEW.md`.

- название продукта, иконки и пользовательский текст;
- default/pinned rendezvous и relay endpoints;
- trust policy публичного ключа сервера;
- запрет fallback на публичную стороннюю инфраструктуру;
- отключение upstream custom-client trust channel;
- packaging/installers и update channel;
- позже — saved-device UX и понятные aliases поверх существующего числового ID.

## Области, которые стараемся держать близко к upstream

- video/audio pipeline;
- screen capture;
- keyboard/mouse transport;
- clipboard/file transfer protocol;
- NAT traversal и relay protocol;
- platform-specific low-level code.

## Версионирование

FuntiDesk использует собственную версию продукта. В release notes и build metadata фиксируются версии/commits client, server и обеих копий `hbb_common`, вошедшие в конкретный релиз.

## Слияние RustDesk 1.5.0 (2026-10-11)

- Механизм: `git merge -X subtree=client` тега `1.5.0`, затем `-X subtree=client/libs/hbb_common` коммита `229b904`; история upstream сохранена.
- В 1.5.0 upstream вынес из `hbb_common` в новый крейт `client/libs/base` `message.proto`, ключи настроек, передачу файлов и часть платформенного кода. Наши поля протокола (номера 1001–1004, ADR-005/006) теперь в `client/libs/base/protos/message.proto`; сервер и ключ FuntiDesk остаются в `client/libs/hbb_common/src/config.rs`.
- Рукопожатия: новый обмен ключами upstream (`kx_version`, подписанные параметры) принят, но без нешифрованных запасных путей и только со встроенным ключом сервера FuntiDesk (`client.rs`, `server.rs`, `common.rs`).
- **WebRTC выключен** (`common::get_webrtc_enabled` всегда `false`, рукопожатие отказывает WebRTC-каналу): по умолчанию он использует публичные STUN-серверы Google, Cloudflare и других — стороннюю инфраструктуру. Включение — отдельный ADR со своими STUN/TURN.
- Удалены вслед за upstream: Linux headless, система плагинов (проверка идентичности требует, чтобы её не было).
- vcpkg закреплён на `9e593bb18ea69cc5095e012465dcd675a822ed0d`, как в upstream 1.5.0; Rust 1.75, Flutter 3.24.5, NDK r28c не менялись.
- Версия для людей — `1.5.0-ft.<N>`.

## Как сливать новый RustDesk (памятка по опыту 1.5.0)

1. Новая ветка от `main`. Получить тег: `git fetch --no-tags https://github.com/rustdesk/rustdesk.git refs/tags/<тег>:refs/tags/upstream-client-<тег>`; узнать коммит `hbb_common` в теге (`git ls-tree upstream-client-<тег> libs/hbb_common`) и получить его.
2. До слияния — `scripts/upstream/funtidesk-patches.sh` (что у нас изменено) и `docs/FUNTIDESK_PATCHES.md` (зачем).
3. `git merge --no-ff -X subtree=client upstream-client-<тег>`; конфликт `libs/hbb_common` (gitlink против папки) — удалить заглушку; затем `git merge -X subtree=client/libs/hbb_common <коммит>`.
4. Разрешать конфликты так: берётся код upstream, наши правки накладываются заново с меткой `FUNTIDESK`. Особое внимание: рукопожатия (`client.rs`, `server.rs`, `common.rs`) — без нешифрованных путей и только встроенный ключ; вход (`server/connection.rs`) — порядок: проверки upstream, затем семья, звонок только звонит.
5. Проверить, не переехали ли файлы (в 1.5.0 `message.proto`, ключи настроек и `fs` ушли в `libs/base`) — наши поля протокола переносятся с теми же номерами.
6. Новые функции upstream, которые ходят наружу (в 1.5.0 — WebRTC с публичными STUN), выключить до отдельного ADR; новые запросы relay — только `secure = true`.
7. Закрепления инструментов: сравнить `VCPKG_COMMIT_ID`, `RUST_VERSION`, `FLUTTER_VERSION`, `NDK_VERSION` в `.github/workflows/flutter-build.yml` upstream с `scripts/windows/bootstrap.ps1` и `.github/workflows/android-apk.yml`.
8. Сборка (`build-baseline.ps1`), все `scripts/ci/test-*.sh`, `funtidesk-patches.sh` после слияния — каждая правка из `FUNTIDESK_PATCHES.md` на месте.
9. Приёмка на двух компьютерах: новая ↔ старая версия и новая ↔ новая (управление, файлы, терминал, звонок, семья, обновление кнопкой); отчёт — `docs/reviews/`.
10. Обновить этот файл (теги и коммиты) и `FUNTIDESK_PATCHES.md`.