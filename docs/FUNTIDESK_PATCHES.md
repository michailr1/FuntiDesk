# Наши правки в коде upstream

Что FuntiDesk меняет в исходниках RustDesk и зачем. Нужен при каждом слиянии нового upstream (`docs/UPSTREAM.md`, «Как сливать новый RustDesk»): каждая правка из этого списка после слияния должна остаться на месте и работать.

Полный и всегда актуальный перечень файлов — `scripts/upstream/funtidesk-patches.sh` (разница с тегом upstream и число меток `FUNTIDESK` в каждом файле). На 2026-10-12 против RustDesk 1.5.0 — около 130 файлов `client/`, плюс `server/`.

Правило для кода: каждая правка в файле upstream помечается комментарием `FUNTIDESK` с причиной (и ADR, если есть). Новые модули FuntiDesk — в отдельных файлах `funti_*`, в файлах upstream — тонкие вызовы.

## Безопасность (ADR-001…004, SECURITY.md, R-10…R-15)

| Где | Что | Проверка |
|---|---|---|
| `client/libs/hbb_common/src/config.rs` | сервер `desk.funti.cc` и его ключ зашиты, без запасных публичных серверов; имя `FuntiDesk`; профиль RustDesk никогда не читается (решение владельца 2026-10-28), на macOS переносится только прежний каталог самого FuntiDesk | `test-r12-production-binding.sh`, `test-funtidesk-product-identity.sh` |
| `client/src/client.rs` (`secure_connection`), `client/src/server.rs` (`identity_handshake`) | рукопожатие только шифрованное, только со встроенным ключом сервера; любой сбой — отказ; WebRTC — отказ | `test-r10-fail-closed.sh` |
| `client/src/client.rs` (relay) | relay всегда `secure = true`; при сбое прямого рукопожатия — одна попытка через relay | `test-r10-fail-closed.sh` |
| `client/src/common.rs` | `key_exchange` только со встроенным ключом; WebSocket выключен; `get_webrtc_enabled() = false`; свой адрес API/обновлений не настраивается | `test-r14-runtime-endpoints.sh` |
| `client/src/common.rs` (`check_software_update`), `updater.rs` | обновления upstream выключены, своё обновление — `funti_update.rs` (ADR-007) | `test-r14-runtime-endpoints.sh` |
| `client/src/custom_server.rs`, `read_custom_client` | настройка клиента по имени exe и чужая подпись конфигурации выключены (ADR-002) | `test-r11-…`, `test-r13-…` |
| безопасные настройки по умолчанию | (R-15) | `test-r15-safe-defaults.sh` |
| система плагинов | убрана upstream в 1.5.0, не должна вернуться | `test-funtidesk-product-identity.sh` |

## Идентичность продукта

Имя FuntiDesk, иконки, `FuntiDesk.exe`, метаданные Windows/Android/macOS, пространства имён службы, каналов, временных папок (`.funtidesk*`), однофайловый exe (`libs/portable`: `%LOCALAPPDATA%\FuntiDesk\portable`), переводы без «RustDesk» в интерфейсе. Настройки полностью отдельные: ID, ключи, параметры, сохранённые устройства, адресная книга и группы RustDesk на том же компьютере FuntiDesk не копирует (найдено на Kali 2026-10-28: в FuntiDesk появлялись устройства RustDesk). ID новой установки выводится из MAC иначе, чем в RustDesk, и не совпадает с ним (`funti_id_from_mac`). `client/src/funti_separation.rs` однократно, когда впервые находит профиль RustDesk, только читает его для сравнения: равный ID заменяется новым, а сохранённые устройства, избранное, адресная книга и группы, которые есть и в RustDesk, удаляются из FuntiDesk. Проверка — `scripts/ci/test-funtidesk-product-identity.sh`.

## Протокол (номера от 1000)

| Где | Что | ADR |
|---|---|---|
| `client/libs/base/protos/message.proto` (с 1.5.0; раньше `hbb_common`) | `LoginRequest` 1001–1004 (семья), `LoginResponse` 1001, `Misc.funti_call_back_request` 1001 | 005, 006 |
| `client/libs/hbb_common/protos/rendezvous.proto` и `server/libs/hbb_common/protos/rendezvous.proto` | `FuntiPairOffer/Lookup/Response` 1001–1003 | 008 |

## Свои функции и где они цепляются к upstream

| Функция | Наш модуль | Вызовы в коде upstream |
|---|---|---|
| Звонки, «Камера недоступна» | `funti_ring.rs` | `server/connection.rs` (звонок только звонит, в т. ч. по свежему сеансу), `server/video_service.rs`, `server/service.rs`, `client/io_loop.rs`, `ipc.rs`, `toolbar.dart` («Позвонить» в меню сеанса) |
| Семья, «Попросить помощи», добавление по коду, права членов семьи | `funti_family.rs`, `funti_family.dart` | `server/connection.rs` (`funti_family_login`), `ipc.rs` (в т. ч. `keep_family` — список семьи не затирается кэшем настроек интерфейса), `flutter_ffi.rs`, `client.rs` (`handle_hash`); права — `server/connection.rs` (`funti_family_login`), `ipc.rs` (`FuntiFamilyRights`); право «Менять настройки FuntiDesk» — `server/connection.rs` (`funti_family_remote_modify_state`), `ipc.rs` (`ControlPermissionsRemoteModify`) |
| Обновление кнопкой, оповещение о новой версии | `funti_update.rs`, `funti_update_notice.dart` | `core_main.rs` (`--funti-finish-update`, очистка), `flutter_ffi.rs`, «О программе», `funti_home_view.dart` (окошко на главном экране), `libs/portable/src/main.rs` (`FUNTIDESK_PORTABLE_EXE`, `--funti-wait-pid`); служба — `ipc.rs` (`FuntiUpdateService`), `core_main.rs` (`--server`: `cleanup_service`) |
| Номер сборки `X.Y.Z-ft.N` | `build.rs` | `core_main.rs` (`--version`), `ui_interface.rs` |
| Пересчёт NAT при смене сети (бывший MIK-16) | `funti_network.rs` | `rendezvous_mediator.rs` (`start_all`: запуск монитора), `common.rs` (`test_nat_type`: один тест за раз; `test_nat_type_`: перерегистрация при смене типа NAT) |
| Журнал запусков и выходов `--server` в службе, без запуска в «нет сессии» (2026-10-22, `docs/reviews/2026-10-22-unattended-after-reboot.md`) | `platform/windows/funti_service.rs` | `platform/windows.rs` (`run_service`), `platform/windows.cc` (`LaunchProcessWin`: код ошибки), `rendezvous_mediator.rs` (журнал `PunchHole`/`RequestRelay`) |
| Сигнализация по TCP | — | `rendezvous_mediator.rs`, `server/src/rendezvous_server.rs` (ADR-004) |
| Передача файлов: `%переменные%`, быстрые папки | — | `common.rs` (`funti_expand_env`), `ui_cm_interface.rs`, `flutter_ffi.rs`, `file_manager_page.dart`, `file_model.dart` |
| Передача файлов: вставка из буфера обмена (кнопка и Ctrl+V на панели удалённого компьютера) | `funti_clipboard_files.rs` (Windows — `CF_HDROP`, Linux/macOS — `arboard`) | `lib.rs`, `flutter_ffi.rs` (`main_funti_clipboard_files`), `file_manager_page.dart` (`_funtiPasteFromClipboard`), `file_model.dart` (`funtiSendPaths`: пустые подпапки — от папки самого файла, а не от открытой слева) |
| Передача файлов: миниатюры фото (ADR-017) — сообщения `FuntiReadThumbnail`/`FuntiThumbnail` (поля 1001, старые версии их игнорируют); миниатюру делает процесс пользователя на компьютере с файлом: JPEG/PNG/GIF/BMP/WebP до 50 МБ и 40 Мп, до 256 px, поворот по EXIF, ответ до 32 КБ (2026-11-03) | `funti_thumbnail.rs` (тесты в модуле) | `message.proto`, `ipc.rs` (`FS::FuntiReadThumbnail`), `server/connection.rs`, `ui_cm_interface.rs` (`funti_read_thumbnail`), `client/file_trait.rs`, `client/io_loop.rs`, `ui_session_interface.rs`, `flutter.rs` (событие `funti_thumbnail`), `flutter_ffi.rs` (`session_funti_read_thumbnail`) |
| Журнал подключений на компьютере (ADR-020): кто вошёл, длительность, число и размер файлов, отклонённые попытки; только локально, до 2 МБ (2026-11-11) | `funti_journal.rs`, `funti_journal/store.rs` (тесты — `scripts/ci/test-funti-journal.sh`) | `server/connection.rs` (по одной строке в `post_conn_audit`, `post_file_audit`, `post_alarm_audit`) |
| Передача файлов: режим «Миниатюры» на каждой панели (кнопка рядом с «Ещё», запоминается) — строки выше, у фото превью 48 px; свои файлы декодирует окно, удалённые запрашиваются только для видимых строк, по две за раз, кэш в памяти до 1000; без ответа трижды — сообщение «обновите FuntiDesk» (ADR-017, 2026-11-03) | — | `file_manager_page.dart` (`_funtiThumbs`, `_funtiIcon`, `_FuntiThumb`), `file_model.dart` (`FuntiThumbnails`, `funtiIsPicture`), `model.dart` (событие `funti_thumbnail`) |
| Передача файлов: меню правой кнопки (строка и пустое место), «Копировать»/«Вставить» между панелями (Ctrl+C/Ctrl+V), «Переименовать» (F2), «Удалить» (Del) с одним подтверждением на всё выбранное (2026-11-03) | — | `file_manager_page.dart` (`_funtiShortcuts`, `_funtiShowEntryMenu`, `_funtiShowFolderMenu`, `_funtiConfirmDelete`), `file_model.dart` (`FileModel.funtiCopied`; `funtiSendPaths` в обе стороны; `removeAction(funtiConfirmed:)`), управляющие символы в поиске по буквам с 1.5.3 отсекает сам upstream |
| Передача файлов: клавиши Backspace/Ctrl+A/F5/Ctrl+Shift+C (стрелки, PgUp/PgDn, Home/End и Enter с 1.5.3 — upstream; наш крючок — Enter на файле открывает его, высота строки для режима миниатюр), строка «Объектов · Выбрано, размер», пункты «Размер» (папки — рекурсивно, до 60 с) и «Скопировать путь» (2026-11-03) | — | `file_manager_page.dart` (`_funtiMove`, `_funtiStatusBar`, `_funtiShowSize`, `_funtiCopyPath`), `file_model.dart` (`fetchDirectoryRecursiveToRemove(timeout:)`) |
| Передача файлов: «Открыть» файл (двойной клик, Enter, меню) — свой открывается программой, удалённый скачивается в `Загрузки\FuntiDesk` под свободным именем и открывается после загрузки; своей программой открываются только документы, картинки, звук и видео из списка разрешённых (`_funtiOpenable`), всё остальное показывается в папке; скачанное с другого компьютера получает метку Windows «из интернета» (`funtiMarkDownloaded`, Zone.Identifier, зона 3); «Показать в папке» у завершённых скачиваний; сообщение «Передача завершена»; «Отправить на Рабочий стол / в Загрузки» другого компьютера (2026-11-03) | — | `file_manager_page.dart` (`_funtiOpenFile`, `_funtiQuickSend`, `_funtiShowInFolder`), `file_model.dart` (`funtiSendPaths(names:)` возвращает id, `JobController.funtiOnDone`/`funtiSetTo`, `funtiFreeName`) |
| Передача файлов: совпадающие имена в папке назначения — один вопрос на всю передачу: «Оставить оба» (имя «файл (2)», по умолчанию), «Заменить» (заранее отвечает «перезаписать» для всей пачки через `rememberTransferConflictBatch`), «Пропустить» (2026-11-03). Перетаскивание из Проводника идёт прежним путём | — | `file_manager_page.dart` (`_funtiSendChecked`, `_funtiAskConflict`), `file_model.dart` (`funtiSendPaths(overwrite:)`) |
| Звук: подбор формата микрофона | — | `server/audio_service.rs` |
| Камера: режим, кадры | — | `libs/scrap/src/common/camera.rs` |
| Интерфейс | `funti_home_view.dart`, `funti_home_scene.dart`, `funti_theme.dart`, `funti_quotes.dart` | `desktop_home_page.dart`, `desktop_setting_page.dart` («О программе»; окно настроек по макету 2026-10-12: вкладки `access`/`family`/`calls`/`advanced`, старые вкладки показываются частями через `_FuntiPart`, `funtiSettingsTab` переводит старые ключи `safety`/`network`/`display`/`printer` на новые), `server_page.dart`, `common.dart`, `consts.dart` |
| Нет сервера аккаунтов (R-14) | — | `flutter_ffi.rs` (`is_disable_account` всегда `true`: скрыты «Аккаунт», «Заметка», аудит), `common.rs` (`get_api_server` пустой) |
| Переводы | ключи `funti-*` | `src/lang/ru.rs`, `en.rs`, `template.rs` |
| Собственный личный кабинет | `funti_account.rs`, `funti_account_windows.rs`, `funti_account_ui.rs`, `funti_account_protocol.rs`, `funti_account.dart` | `lib.rs` (модули), `ipc.rs` (один actor в main IPC и redacted пакет), `flutter_ffi.rs` (FFI с Future в Dart и UI runner), `Cargo.toml` (feature `dpapi` существующего winapi), `desktop_setting_page.dart` (своя вкладка Windows), `funti_home_view.dart` (отдельный список и уведомления); upstream-аккаунт выключен |

`client/libs/hbb_common/src/config.rs` и новый `config/funti_account_storage.rs`: после привязки кабинета Windows сохраняет семью и ledger одним атомарно заменяемым документом; последующие записи настроек сохраняют этот порядок. Whole-map и SyncConfig не перезаписывают служебную привязку/ledger и семью устаревшим кэшем. До привязки прежняя запись настроек сохраняется. Секрет сессии защищён user-scoped DPAPI в службе и не включён в FFI/IPC-ответ. `funti_family.rs` сериализует изменения семьи с применением отзыва под отдельным Windows mutex; других платформ это не меняет.

Ключи `funti-account-*` добавлены в en/ru/template; в остальных языках — пустые значения по `client/AGENTS.md`. Windows IPC/DPAPI и реальные сеансы требуют отдельной проверки: локальные тесты policy не являются E2E-приёмкой.

## Сервер (`server/`)

`rendezvous_server.rs` — сигнализация по TCP (ADR-004), поиск по коду (`funti_pair.rs`, ADR-008); сборка и развёртывание — `docs/SERVER_DEPLOYMENT.md`.

`server/src/lib.rs` и `server/src/rendezvous_server.rs` — тонкие хуки необязательного внутреннего resolver `funti_account_identity.rs` (проект ADR-010). Он выдаёт account-сервису только зарегистрированный открытый ключ указанного ID через отдельный Unix socket. Без явного `FUNTI_ACCOUNT_IDENTITY_SOCKET` прежний путь не меняется; ошибка resolver не останавливает hbbs. Account не получает базу или приватный ключ hbbs. Проверки account — `.github/workflows/account-ci.yml`; реальные клиенты и production ещё не проверены.
