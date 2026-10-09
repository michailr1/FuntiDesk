# Android-клиент FuntiDesk

**Статус:** начат 2026-10-09 по решению владельца (вне порядка AGENTS.md: Android раньше Family Release для Windows). Тестовые сборки — без подписи релиза, не для распространения.

## Что входит в первый этап

- Сборка APK в CI (`.github/workflows/android-apk.yml`) тем же путём, что upstream (`build-rustdesk-android`): мост `flutter_rust_bridge` на Ubuntu, `librustdesk.so` через `cargo-ndk`, APK Flutter. Только `arm64-v8a` — почти все телефоны последних лет.
- Тестовая подпись — отладочный ключ Android SDK раннера CI. Секретов подписи в репозитории нет. Релиз в GitHub: `funtidesk-android-<коммит>`, помечен как pre-release и никогда не «latest» (latest — Windows-релиз для `install.ps1`).
- Идентичность: название «FuntiDesk», схема `funtidesk://`, действия `cc.funti.funtidesk.*`, иконки из `design/brand/funtidesk-mark.svg` (`scripts/brand/export_android_icons.py`).
- Модель доверия та же, что на Windows: общий `hbb_common` — закреплённые `desk.funti.cc` и ключ сервера (R-12), без публичного запасного сервера, без `custom-client`, TCP-сигнализация (ADR-004).

## Решение: свой applicationId (2026-10-09, на утверждение владельцу)

`applicationId` сменён с upstream `com.carriez.flutter_hbb` на `cc.funti.funtidesk`.

- Пользователей Android-версии FuntiDesk не было, переносить данные некому, поэтому отложенная «миграция данных Android» больше не нужна.
- С upstream-идентификатором FuntiDesk нельзя поставить на телефон, где уже стоит RustDesk (одинаковый пакет, разные подписи), и магазины/лаунчеры путали бы приложения.
- Пакет Kotlin-кода (`com.carriez.flutter_hbb`) не меняется: это код, а не идентичность, его переименование — большой и бесполезный для пользователя дифф.
- CI-проверка `scripts/ci/test-funtidesk-product-identity.sh` теперь требует новый идентификатор.

## Дальше

- Приёмка на телефоне владельца: установка APK, телефон → компьютер (управление, файлы, звонок), компьютер → телефон (демонстрация экрана), семейный доступ (ADR-006).
- Собственный мобильный интерфейс по системе FuntiDesk — только по утверждённому макету (UI-решения владельца: не переодевать upstream-экраны).
- Подпись релиза и канал распространения — отдельное решение (хранение ключа, ответственный).
