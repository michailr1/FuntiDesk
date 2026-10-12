# Наши правки в коде upstream

Что FuntiDesk меняет в исходниках RustDesk и зачем. Нужен при каждом слиянии нового upstream (`docs/UPSTREAM.md`, «Как сливать новый RustDesk»): каждая правка из этого списка после слияния должна остаться на месте и работать.

Полный и всегда актуальный перечень файлов — `scripts/upstream/funtidesk-patches.sh` (разница с тегом upstream и число меток `FUNTIDESK` в каждом файле). На 2026-10-12 против RustDesk 1.5.0 — около 130 файлов `client/`, плюс `server/`.

Правило для кода: каждая правка в файле upstream помечается комментарием `FUNTIDESK` с причиной (и ADR, если есть). Новые модули FuntiDesk — в отдельных файлах `funti_*`, в файлах upstream — тонкие вызовы.

## Безопасность (ADR-001…004, SECURITY.md, R-10…R-15)

| Где | Что | Проверка |
|---|---|---|
| `client/libs/hbb_common/src/config.rs` | сервер `desk.funti.cc` и его ключ зашиты, без запасных публичных серверов; имя `FuntiDesk`, перенос старого профиля | `test-r12-production-binding.sh`, `test-funtidesk-product-identity.sh` |
| `client/src/client.rs` (`secure_connection`), `client/src/server.rs` (`identity_handshake`) | рукопожатие только шифрованное, только со встроенным ключом сервера; любой сбой — отказ; WebRTC — отказ | `test-r10-fail-closed.sh` |
| `client/src/client.rs` (relay) | relay всегда `secure = true`; при сбое прямого рукопожатия — одна попытка через relay | `test-r10-fail-closed.sh` |
| `client/src/common.rs` | `key_exchange` только со встроенным ключом; WebSocket выключен; `get_webrtc_enabled() = false`; свой адрес API/обновлений не настраивается | `test-r14-runtime-endpoints.sh` |
| `client/src/common.rs` (`check_software_update`), `updater.rs` | обновления upstream выключены, своё обновление — `funti_update.rs` (ADR-007) | `test-r14-runtime-endpoints.sh` |
| `client/src/custom_server.rs`, `read_custom_client` | настройка клиента по имени exe и чужая подпись конфигурации выключены (ADR-002) | `test-r11-…`, `test-r13-…` |
| безопасные настройки по умолчанию | (R-15) | `test-r15-safe-defaults.sh` |
| система плагинов | убрана upstream в 1.5.0, не должна вернуться | `test-funtidesk-product-identity.sh` |

## Идентичность продукта

Имя FuntiDesk, иконки, `FuntiDesk.exe`, метаданные Windows/Android/macOS, пространства имён службы, каналов, временных папок (`.funtidesk*`), однофайловый exe (`libs/portable`: `%LOCALAPPDATA%\FuntiDesk\portable`), переводы без «RustDesk» в интерфейсе. Проверка — `scripts/ci/test-funtidesk-product-identity.sh`.

## Протокол (номера от 1000)

| Где | Что | ADR |
|---|---|---|
| `client/libs/base/protos/message.proto` (с 1.5.0; раньше `hbb_common`) | `LoginRequest` 1001–1004 (семья), `LoginResponse` 1001, `Misc.funti_call_back_request` 1001 | 005, 006 |
| `client/libs/hbb_common/protos/rendezvous.proto` и `server/libs/hbb_common/protos/rendezvous.proto` | `FuntiPairOffer/Lookup/Response` 1001–1003 | 008 |

## Свои функции и где они цепляются к upstream

| Функция | Наш модуль | Вызовы в коде upstream |
|---|---|---|
| Звонки, «Камера недоступна» | `funti_ring.rs` | `server/connection.rs` (звонок только звонит, в т. ч. по свежему сеансу), `server/video_service.rs`, `server/service.rs`, `client/io_loop.rs`, `ipc.rs`, `toolbar.dart` («Позвонить» в меню сеанса) |
| Семья, «Попросить помощи», добавление по коду | `funti_family.rs`, `funti_family.dart` | `server/connection.rs` (`funti_family_login`), `ipc.rs` (в т. ч. `keep_family` — список семьи не затирается кэшем настроек интерфейса), `flutter_ffi.rs`, `client.rs` (`handle_hash`) |
| Обновление кнопкой | `funti_update.rs` | `core_main.rs` (`--funti-finish-update`, очистка), `flutter_ffi.rs`, «О программе» |
| Номер сборки `X.Y.Z-ft.N` | `build.rs` | `core_main.rs` (`--version`), `ui_interface.rs` |
| Сигнализация по TCP | — | `rendezvous_mediator.rs`, `server/src/rendezvous_server.rs` (ADR-004) |
| Передача файлов: `%переменные%`, быстрые папки | — | `common.rs` (`funti_expand_env`), `ui_cm_interface.rs`, `flutter_ffi.rs`, `file_manager_page.dart`, `file_model.dart` |
| Звук: подбор формата микрофона | — | `server/audio_service.rs` |
| Камера: режим, кадры | — | `libs/scrap/src/common/camera.rs` |
| Интерфейс | `funti_home_view.dart`, `funti_home_scene.dart`, `funti_theme.dart`, `funti_quotes.dart` | `desktop_home_page.dart`, `desktop_setting_page.dart` («О программе»), `server_page.dart`, `common.dart`, `consts.dart` |
| Переводы | ключи `funti-*` | `src/lang/ru.rs`, `en.rs`, `template.rs` |

## Сервер (`server/`)

`rendezvous_server.rs` — сигнализация по TCP (ADR-004), поиск по коду (`funti_pair.rs`, ADR-008); сборка и развёртывание — `docs/SERVER_DEPLOYMENT.md`.
