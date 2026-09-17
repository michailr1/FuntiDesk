# Upstream baseline и политика синхронизации

## Baseline

FuntiDesk стартует со стабильных версий исходных проектов, зафиксированных на 2026-09-17:

- Client: `rustdesk/rustdesk`, tag `1.4.9`, commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`.
- Server: `rustdesk/rustdesk-server`, tag `1.1.16`, commit `73523b31cfd25d77dee862e6fc9f5e1fb5e485ef`.
- Shared library: `rustdesk/hbb_common`, подключён в обоих проектах как git submodule
  `libs/hbb_common` и закреплён на разных коммитах:
  - для клиента — `7e1c392c62d39c364127307cd408421dd5f8cfb0`;
  - для сервера — `83419b6549636ee39dacef7776c473f5802e08d6`.

`hbb_common` — не вспомогательная зависимость: именно в нём находится
`src/config.rs` с адресами rendezvous-серверов, публичным ключом и логикой выбора
сервера, то есть основной предмет форка.

Мы сознательно не используем плавающий `master` как baseline.

## Структура репозитория

FuntiDesk планируется как единый продуктовый репозиторий с двумя деревьями, происходящими от upstream:

```text
/client                    # клиентская кодовая база
/client/libs/hbb_common    # общая библиотека на клиентском пине
/server                    # серверная кодовая база
/server/libs/hbb_common    # общая библиотека на серверном пине
/docs
/infra
```

`hbb_common` импортируется дважды, каждое дерево — на своём upstream-пине.
Обоснование и рассмотренные альтернативы: `docs/FORK_PLAN.md`.

Начальный импорт исходного кода по возможности должен сохранять историю upstream. Предпочтителен history-preserving import (`git subtree` или эквивалент), а не copy-paste snapshot. Submodule на upstream-репозиторий в production-сборке не используется: это сделало бы сборку невоспроизводимой из нашего репозитория.

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

## Области ожидаемого расхождения

Конкретный минимальный patch set с указанием файлов приведён в `docs/FORK_PLAN.md`.

- название продукта, иконки и пользовательский текст;
- default/pinned rendezvous и relay endpoints;
- trust policy публичного ключа сервера;
- запрет fallback на публичную стороннюю инфраструктуру;
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

FuntiDesk использует собственную версию продукта. В release notes и build metadata фиксируются версии/commits клиентского и серверного upstream baseline, вошедшие в конкретный релиз.