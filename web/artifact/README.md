# FuntiDesk production web source

Source: https://funtidesk-sites-v1.michailr.chatgpt.site/
Migration date: 2026-10-12.

This `web/artifact/` directory is the production source for the published Sites v1 web artifact.

Канонический motion-lab сохранён: hero, типографика, тёмная композиция, canvas/motion и исходное начертание mark. Обновлён только встроенный клиентский концепт, чтобы приблизить его к desktop UI.

Источник проверки интерфейса: точный `origin/main` на момент реализации — `7370e0c9d0c16dab652c9e6d56210b51f2543cf1`. Сверены `desktop_home_page.dart`, `funti_home_view.dart`, `funti_family.dart`, `funti_home_scene.dart`, `remote_toolbar.dart`, `funti_theme.dart` и `docs/PRODUCT.md`.

Демо работает только в браузере: нет реальной инфраструктуры, устройств, камеры/микрофона или настоящих учётных данных. ID и пароль вымышлены. Семейный список, запрос помощи и звонок показаны как локальные интерактивные концепты; Android/iOS не представлены как готовые полноценные клиенты.

`manifest.json` фиксирует точные размеры и SHA-256 публичных файлов `web/artifact/`. Деплой использует только этот каталог; `web/` root не является источником дизайна.
