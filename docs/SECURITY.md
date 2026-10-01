# Модель безопасности FuntiDesk

Статус: baseline M0 + security perimeter M2 (в ручной acceptance до Family Release)

## Цель

FuntiDesk должен работать только через инфраструктуру, которой мы доверяем и которую контролируем. Ошибки конфигурации в security-критичных местах должны приводить к отказу соединения, а не к автоматическому переходу на стороннюю инфраструктуру.

## Границы доверия

Доверенными считаются:

- конкретный production hostname/endpoint FuntiDesk;
- публичный ключ нашего сервера, встроенный или закреплённый в production-сборке;
- подписанные нами релизные артефакты после появления release-signing;
- локальная конфигурация, разрешённая политикой FuntiDesk.

Не считаются доверенными по умолчанию:

- публичные rendezvous/relay-серверы upstream;
- пользовательский произвольный endpoint в production-сборке;
- внешний `custom.txt`/custom-client payload;
- сторонние update URL и web-console URL;
- конфигурационные подписи, ключи которых нам не принадлежат.

## Fail closed

Production-клиент не должен иметь скрытого fallback на публичную инфраструктуру. Если наш server endpoint или server public key отсутствует, повреждён либо не проходит проверку, соединение не устанавливается.

На baseline upstream это свойство требует изменения исходников: в `hbb_common/src/config.rs` присутствуют публичный rendezvous endpoint и upstream public key как константы, используемые как fallback.

## Custom client

Механизм upstream `read_custom_client()` в production FuntiDesk отключается полностью. Решение зафиксировано в `ADR-002-custom-client-trust.md`.

## Доступ к устройству

Разделяем два режима:

1. **Временный доступ** — предназначен для разовой поддержки; временный пароль должен быть явно видим как временный и сменяемый.
2. **Постоянный (unattended) доступ** — включается явно владельцем устройства, хранение секрета должно использовать штатные защищённые механизмы платформы/приложения, а UI не должен смешивать его с временным доступом.

Скрытый удалённый доступ без ведома владельца устройства не является целью проекта.

## Серверные ключи

- private key сервера не хранится в Git;
- persistent server identity резервируется отдельно от репозитория;
- процедура backup/restore должна быть описана до production-развёртывания;
- потеря ключа рассматривается как смена server identity и требует контролируемой ротации доверия клиента;
- публичный ключ сервера **не является секретом**: он позволяет клиенту проверять подлинность инфраструктуры FuntiDesk и защищает от подмены сервера;
- наличие публичного ключа само по себе **не ограничивает, кто может пользоваться сервером**. Доступ к конкретному устройству регулируется temporary/permanent password, approve-mode и другими policy-настройками клиента.

## Внешние обращения

До Family Release проводится аудит сетевых endpoint клиента. Обновления, документация, web-console и прочие upstream URL либо заменяются нашими, либо отключаются, если функция не нужна.

## Критерии security acceptance Windows MVP

- нет обращения к публичному rendezvous/relay upstream при рабочей и ошибочной конфигурации;
- неправильный/неизвестный server key приводит к отказу;
- `custom.txt` не способен изменить поведение production-клиента;
- отсутствует скрытая подмена server endpoint пользовательской настройкой в обычной production-сборке;
- временный и постоянный доступ проверяются отдельно;
- список внешних сетевых endpoint задокументирован и проверен.


## Production access defaults (R-15)

| Опция / поведение | Production значение | Пользователь может менять? | Причина |
|---|---|---|---|
| `direct-server` | `N` | Нет, hard/overwrite policy | Не разрешать обход rendezvous trust path через прямой IP-доступ |
| `enable-lan-discovery` | `N` | Нет, hard/overwrite policy | LAN discovery не входит в M2 security perimeter |
| `allow-remote-config-modification` | `N` | Нет, hard/overwrite policy | Удалённая сторона не должна менять локальную security-конфигурацию |
| insecure TLS fallback | `N` | Нет, hard/overwrite policy | TLS/transport error приводит к отказу |
| WebSocket rendezvous/relay transport | `N` | Нет, hard/overwrite policy | Production M2 публикует только 21115–21117 и не использует 21118/21119 |
| постоянный unattended password | Не задан на clean install | Да, только через явный будущий product flow владельца | Не включать скрытый постоянный доступ по умолчанию |
| `approve-mode` | `password` | Да, если product policy позднее разрешит | Явная аутентификация до сессии |
| `verification-method` | `use-temporary-password` | Да, если product policy позднее разрешит | Clean install использует временный пароль |
| temporary password length | `8` | Да | Временный доступ остаётся основным clean-install режимом |

Значения сетевого exposure (`direct-server`, LAN discovery, remote config и insecure fallback) задаются через `OVERWRITE_SETTINGS` и не должны быть отменяемы обычной пользовательской конфигурацией. Authentication defaults задаются через `DEFAULT_SETTINGS`: это безопасный clean-install baseline, а не запрет будущего явно включённого unattended-доступа.

## Расширенная security acceptance M2 (R-16)

Перед передачей Windows-сборки людям должны быть подтверждены следующие свойства:

- **P7 / secure handshake:** `client/src/client.rs::secure_connection()` и `client/src/server.rs::create_tcp_connection()` отказывают при отсутствующем/невалидном signed peer key, несовпадении peer ID, пустом/невалидном `PublicKey`, пустом encryption material и попытке plaintext session.
- **P8 / executable-name channel:** имя EXE не может изменить rendezvous, relay, API endpoint или server key.
- **P9 / trust anchor:** `get_key()` всегда возвращает закреплённый FuntiDesk server public key; upstream `RS_PUB_KEY` не является fallback.
- **P10 / exposure policy:** direct-server, LAN discovery, remote config modification, WebSocket transport и insecure TLS fallback заблокированы production policy; clean-install authentication defaults используют temporary password.

Автоматические source-policy tests не заменяют E2E. Для R-10 обязательно остаются live/negative проверки с wrong key/fake rendezvous/invalid handshake. Для R-14 — packet/DNS capture чистой Windows VM по `docs/NETWORK_ALLOWLIST.md`.
