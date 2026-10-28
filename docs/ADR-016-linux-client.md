# ADR-016: клиент для Linux

Статус: решение владельца 2026-10-25 — сделать FuntiDesk для Linux и подключить его компьютер с Kali Linux (x86_64, X11, XFCE). Реализация — PR из ветки `claude/linux-build`.

## Решение

Используем Linux-код клиента upstream без изменений; своё — только сборка и упаковка.

- **Сборка** — `scripts/linux/build-deb.sh`, workflow `Linux build`: GitHub Actions `ubuntu-22.04`, те же версии, что у Windows (Rust 1.75, flutter_rust_bridge 1.80.1, Flutter 3.22.3 для моста и 3.24.5 с патчем upstream для сборки, тот же коммит vcpkg). Функции `hwcodec`, `flutter`, `unix-file-copy-paste`, как у upstream. Workflow выкладывает артефакт на 14 дней; запуск на `main` также публикует релиз `funtidesk-linux-<коммит>` (prerelease, не latest: latest остаётся за Windows, его берут `install.ps1` и обновление). Решение владельца 2026-10-28.
- **Пакет** — `funtidesk-<версия>-x86_64.deb`, версия как у Windows (`1.5.0-ft.N`). Имена свои: `/usr/share/funtidesk`, `/usr/bin/funtidesk`, служба `funtidesk.service`, ярлыки `funtidesk.desktop` и `funtidesk-link.desktop` (схема `funtidesk://`), значки FuntiDesk. Код Linux управляет службой и ищет процессы по имени приложения в нижнем регистре — `funtidesk`, поэтому упаковка upstream с именами `rustdesk` не подходит. Файлы — `client/res/funtidesk-linux/`; `res/rustdesk.*` и `res/DEBIAN` upstream не меняются.
- **Безопасность** та же, что у Windows: закреплённые сервер и ключ, TCP-сигнализация по умолчанию (ADR-004), fail closed. Служба работает от root, как у upstream.

## Ограничения

- Только x86_64 и glibc 2.35 и новее (Ubuntu 22.04+, Debian 12+, Kali Rolling). ARM — отдельно, если понадобится.
- Полноценное удалённое управление — в сеансе X11. Под Wayland upstream требует разрешения на каждое подключение и не даёт экран входа; вариант `drm` (без подтверждения) не собираем.
- Свои функции Windows, завязанные на Windows API (кабинет с DPAPI, обновление кнопкой ADR-007), на Linux не включаются; обновление — новой версией пакета.

## Проверка

CI собирает пакет. Приёмка — на компьютере владельца с Kali: установка `sudo apt install ./funtidesk-….deb`, служба активна и регистрируется по TCP, подключение с Windows и на Windows (экран, управление, буфер обмена, файлы), доступ после перезагрузки на экране входа, удаление пакета.
