# FuntiDesk: владение namespace и миграция идентичности

Статус: pre-UI architecture baseline  
База этапа: `f8e3a1a679f3317557e162807868700468cba004`

## Цель

До редизайна UI убрать наследуемую идентичность RustDesk из всех поверхностей, которыми владеет FuntiDesk как продукт.

Пользователь и ОС не должны видеть `RustDesk`/`rustdesk` в имени дистрибутива, основном executable, продуктовых метаданных, новых каталогах профиля/логов/конфигурации, собственных service/task/registry namespace и иных FuntiDesk-owned runtime identifiers.

Это **не** означает слепую замену каждой строки `RustDesk`. Ссылки на upstream, лицензии, авторство, имена внешних зависимостей и элементы wire/source compatibility сохраняются там, где они технически или юридически необходимы.

## Правило владения namespace

### A. FuntiDesk product/runtime namespace — обязательно переименовать

Эти идентификаторы принадлежат продукту и должны быть FuntiDesk-native:

- основной Windows executable и пользовательские build artifacts: `FuntiDesk.exe`;
- Windows `FileDescription`, `InternalName`, `OriginalFilename`, `ProductName`;
- новый пользовательский config/data/log root: `%APPDATA%\FuntiDesk`;
- новые FuntiDesk-owned имена конфигурационных и лог-файлов, если они формируются от имени приложения;
- installer/uninstaller display names и install path;
- Windows service/task/registry namespace, которым управляет наш клиент/installer;
- product-owned IPC/mutex/pipe/window/class names, если их изменение не нарушает внешний protocol compatibility;
- product URL/deep-link scheme: целевое собственное имя `funtidesk://` (legacy compatibility рассматривается отдельно);
- release/archive/artifact names;
- product-facing docs, UI strings и diagnostics.

### B. FuntiDesk-owned source/architecture namespace — переименовать поэтапно

Наследуемые внутренние имена, которые не обязаны оставаться upstream-совместимыми, следует переносить после стабилизации runtime identity:

- owned wrappers/adapters/modules;
- собственные CI variables и build-script identifiers;
- каталоги и имена FuntiDesk-specific слоёв;
- package/module names, если rename не создаёт неоправданный конфликт с upstream sync.

Для этой категории приоритет ниже, чем у runtime identity. Переименование выполняется отдельными малыми коммитами.

### C. Upstream/vendor/compatibility namespace — не заменять автоматически

Допустимо и иногда обязательно оставить `RustDesk`/`rustdesk` в:

- LICENSE, NOTICE, copyright и attribution;
- ссылках на upstream repository/issues/docs, когда это источник или техническая ссылка;
- внешних dependency URLs и repository coordinates (`rustdesk-org/...`);
- vendor/upstream crate/package/library names, если rename существенно ухудшает upstream mergeability или ABI/build compatibility;
- legacy migration readers;
- wire/protocol compatibility identifiers, пока отдельно не доказана возможность безопасного изменения.

Любое новое исключение этой категории должно иметь явное техническое или юридическое обоснование.

## Подтверждённые проблемы текущей базы

На базе этапа подтверждены как минимум следующие upstream identities:

1. `client/flutter/windows/CMakeLists.txt`
   - `project(rustdesk ...)`;
   - `BINARY_NAME "rustdesk"`;
   - внутренние `RUSTDESK_LIB*` и `librustdesk.dll`.

2. `client/flutter/windows/runner/Runner.rc`
   - `FileDescription = RustDesk Remote Desktop`;
   - `InternalName = rustdesk`;
   - `OriginalFilename = rustdesk.exe`;
   - `ProductName = RustDesk`;
   - upstream company/copyright metadata.

3. `client/libs/hbb_common/src/config.rs`
   - central `APP_NAME` по умолчанию равен `RustDesk`;
   - desktop config root вычисляется через `directories_next::ProjectDirs` с `APP_NAME`;
   - IPC paths на Linux/macOS также используют `APP_NAME`.

4. `client/Cargo.toml`
   - package `rustdesk`;
   - `default-run = rustdesk`;
   - library `librustdesk`;
   - upstream authors/description.

5. `client/build.py`
   - ожидает `rustdesk(.exe)` как Cargo binary;
   - содержит Linux packaging layout `/usr/share/rustdesk`, `/etc/rustdesk`, `rustdesk.service`, desktop/icon/package names;
   - содержит upstream package metadata.

Эти группы нельзя исправлять одним global replace: часть относится к A, часть к B/C.

## Phase 1 — Windows product/runtime identity

Первый вертикальный срез должен обеспечить:

- clean Windows build выпускает `FuntiDesk.exe`;
- Windows version metadata показывает FuntiDesk;
- новый profile/config/log root — `%APPDATA%\FuntiDesk`;
- FuntiDesk пишет новые данные только в новый root;
- существующий `%APPDATA%\RustDesk` не удаляется и не модифицируется как часть миграции;
- если нового профиля ещё нет, допускается одноразовое безопасное импортирование необходимых legacy settings из `%APPDATA%\RustDesk`;
- network protocol, rendezvous/relay endpoints, pinned server key и security policy не меняются;
- upstream attribution не удаляется.

### Migration invariant

`RustDesk profile -> FuntiDesk profile` — только compatibility input.

После успешной миграции:

- source legacy profile остаётся на месте;
- дальнейшие writes идут только в FuntiDesk namespace;
- повторный запуск не должен перетирать уже существующий FuntiDesk profile данными из legacy каталога;
- приватные identity/key данные нельзя случайно дублировать/перегенерировать без явного анализа текущего формата и E2E-проверки.

Из-за последнего пункта изменение `APP_NAME` без migration path запрещено.

## Phase 2 — Windows OS integration namespace

После Phase 1 отдельно инвентаризировать и переименовать:

- installer/uninstaller entries;
- Windows service names/display names;
- scheduled tasks;
- registry keys;
- URL/deep-link registration;
- firewall rules;
- IPC/mutex/pipe/window-class names;
- shell integrations и shortcuts.

Каждая группа должна иметь migration/cleanup policy. Не удалять legacy state автоматически без отдельного решения владельца.

## Phase 3 — source/package architecture

После стабилизации Windows runtime:

- отделить FuntiDesk-owned product/application layer от upstream-derived core;
- переименовать owned source identifiers;
- определить, какие crate/library names остаются vendor-compatible;
- минимизировать patch surface, который усложняет будущий upstream sync;
- затем распространить namespace policy на Linux/macOS/Android/iOS.

## CI guard

Нужен blocking guard с двумя классами правил:

1. **deny** для product/runtime-owned путей и metadata: новые `rustdesk.exe`, `%APPDATA%\RustDesk` write target, product metadata `RustDesk`, FuntiDesk-owned service/task/registry/artifact names;
2. **documented allowlist** для attribution/vendor/dependency/legacy-read compatibility.

Guard не должен утверждать, что в исходниках вообще нет слова `rustdesk`: это было бы ложной целью и мешало бы соблюдению лицензий и upstream sync.

## Acceptance Phase 1

Минимальное доказательство на Windows:

1. clean CI build на exact commit;
2. artifact содержит `FuntiDesk.exe` и не содержит основного `rustdesk.exe`;
3. version metadata executable — FuntiDesk;
4. запуск с чистым профилем создаёт `%APPDATA%\FuntiDesk` и не создаёт новый `%APPDATA%\RustDesk`;
5. новый профиль сохраняет ID/настройки после restart;
6. legacy-profile migration проверяется на копии профиля; исходный legacy каталог не изменяется;
7. соединение с `desk.funti.cc`, pinned key и базовые connect/control сценарии не регрессируют.

Только пункты 1–3 относятся к build-time. Пункты 4–7 требуют реального Windows runtime и являются подходящим местом для Windows-агента после завершения изменений в коде.
