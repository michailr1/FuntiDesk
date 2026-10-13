# FuntiDesk production web source

FuntiDesk public web demonstration.
Migration date: 2026-10-12.

This `web/artifact/` directory contains the production FuntiDesk web demo.

Интерактивная демонстрация показывает сценарии FuntiDesk локально в браузере.

Источник проверки интерфейса: точный `origin/main` на момент реализации — `7370e0c9d0c16dab652c9e6d56210b51f2543cf1`. Сверены `desktop_home_page.dart`, `funti_home_view.dart`, `funti_family.dart`, `funti_home_scene.dart`, `remote_toolbar.dart`, `funti_theme.dart` и `docs/PRODUCT.md`.

Демо работает только в браузере: нет подключения к инфраструктуре и устройствам, камера и микрофон не используются. ID и пароль вымышлены. Семейный список, запрос помощи и звонок представлены как локальные сценарии; Android/iOS не показаны как готовые полноценные клиенты.

`manifest.json` фиксирует точные размеры и SHA-256 публичных файлов `web/artifact/`. Деплой использует только этот каталог; `web/` root не является источником дизайна.
