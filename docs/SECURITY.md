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

> **Rollback 2026-10-05 (решение владельца):** изначальные R-15 hard-локи сетевого exposure удалены. Опции ниже больше не попадают в `OVERWRITE_SETTINGS`, не залочены в UI и возвращены к pre-R-15 (upstream) поведению: пользователь может менять их в настройках. Clean-install auth-дефолты (временный пароль) сохранены.

| Опция / поведение | Clean-install значение | Пользователь может менять? | Причина |
|---|---|---|---|
| `direct-server` | выключен (upstream default) | Да | Функциональность direct-IP доступа восстановлена решением владельца |
| `enable-lan-discovery` | включён (upstream default) | Да | LAN discovery входит в функциональность клиента |
| `allow-remote-config-modification` | выключен (upstream default) | Да | Опция управляется пользователем, без hard-политики |
| insecure TLS fallback | выключен (upstream default) | Да | Опция управляется пользователем |
| WebSocket rendezvous/relay transport | выключен (upstream default) | Да | Опция управляется пользователем |
| постоянный unattended password | Не задан на clean install | Да, только через явный будущий product flow владельца | Не включать скрытый постоянный доступ по умолчанию |
| `approve-mode` | `password` | Да, если product policy позднее разрешит | Явная аутентификация до сессии |
| `verification-method` | `use-temporary-password` | Да, если product policy позднее разрешит | Clean install использует временный пароль |
| temporary password length | `8` | Да | Временный доступ остаётся основным clean-install режимом |

Clean-install authentication defaults задаются через `DEFAULT_SETTINGS` (`apply_funtidesk_security_policy()` в `client/src/common.rs`): это безопасный baseline, а не запрет будущего явно включённого unattended-доступа. Exposure-опции больше не записываются в `OVERWRITE_SETTINGS` и подчиняются обычной upstream-логике сохранения/чтения пользовательских настроек. Историческое состояние до отката (hard-локи на commit `acaa57bd6e1a5d7104c24c0cd3cc05e5ab256100`) описано в PR #8 и evidence A6.

## Расширенная security acceptance M2 (R-16)

Перед передачей Windows-сборки людям должны быть подтверждены следующие свойства:

- **P7 / secure handshake:** `client/src/client.rs::secure_connection()` и `client/src/server.rs::create_tcp_connection()` отказывают при отсутствующем/невалидном signed peer key, несовпадении peer ID, пустом/невалидном `PublicKey`, пустом encryption material и попытке plaintext session.
- **P8 / executable-name channel:** имя EXE не может изменить rendezvous, relay, API endpoint или server key.
- **P9 / trust anchor:** `get_key()` всегда возвращает закреплённый FuntiDesk server public key; upstream `RS_PUB_KEY` не является fallback.
- **P10 / exposure policy:** R-15 hard-локи exposure удалены решением владельца (2026-10-05): direct-server, LAN discovery, remote config modification, WebSocket transport и insecure TLS fallback — пользовательские опции с upstream-дефолтами; clean-install authentication defaults используют temporary password и сохранены.

Автоматические source-policy tests не заменяют E2E. Для R-10 обязательно остаются live/negative проверки с wrong key/fake rendezvous/invalid handshake. Для R-14 — packet/DNS capture чистой Windows VM по `docs/NETWORK_ALLOWLIST.md`.


## Windows M2 live acceptance runbook

Перед Family Release ручные проверки выполняются на собранном security head и сохраняются как доказательства рядом с логами клиента. Для каждого сценария запускается:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/security-acceptance.ps1 -ExePath <path-to-funtidesk.exe>
```

Минимальный набор сценариев:

1. **Renamed EXE (R-11):** скопировать бинарник под именем вида `FuntiDesk-host=evil.example,key=AAAA.exe`, запустить и подтвердить по логам/соединениям, что rendezvous остаётся `desk.funti.cc:21116`, а конфигурация инфраструктуры не меняется.
2. **Foreign config (R-12):** в пользовательском config задать чужие `custom-rendezvous-server`, `relay-server`, `api-server`, `key`; клиент должен игнорировать их и использовать только FuntiDesk infrastructure/trust anchor.
3. **Wrong/fake server key (R-10):** поднять isolated hbbs/hbbr с другой identity либо использовать тестовый endpoint/fixture. Сессия должна завершиться ошибкой проверки подлинности до удалённого рабочего стола; plaintext downgrade запрещён.
4. **custom.txt (R-13):** положить рядом с EXE upstream-signed или произвольный `custom.txt`; app-name, endpoints и access policy не должны измениться.
5. **Clean install defaults (R-15):** новый профиль: permanent password не задан; temporary password включён; approve-mode/verification-method соответствуют таблице выше. Exposure-опции (direct-server, LAN discovery, remote config, insecure TLS fallback, WebSocket) после rollback 2026-10-05 не залочены и проверяются как «меняемые пользователем» (значение меняется и сохраняется), а не как locked.
6. **Network allowlist (R-14):** очистить DNS cache, запустить клиент, выполнить подключение, повторить при недоступном сервере и при ошибке ключа. DNS/TCP/UDP capture не должен содержать runtime-обращений вне `docs/NETWORK_ALLOWLIST.md`.
7. **Windows↔Windows E2E:** отдельно подтвердить direct P2P и relay fallback после security changes. Для обеих сессий сохранить логи с transport и secure-handshake evidence.

`security-acceptance.ps1` собирает SHA256 бинарника, hashes конфигурационных файлов, active TCP connections и DNS cache до сценария, чтобы доказательства можно было сопоставить с конкретной сборкой и профилем.
