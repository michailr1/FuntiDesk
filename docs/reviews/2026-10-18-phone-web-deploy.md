# Телефонный веб-сеанс на desk — 2026-10-18

Принятый #70 выложен из `main`, source `30fed457e87e67c9584ae40e0a6ab56d0aadadec`. CI этого main: FuntiDesk, Browser client и Account checks — success. Поставка: `/opt/funtidesk-web/releases/30fed457e87e67c9584ae40e0a6ab56d0aadadec-web`, 25 файлов по manifest. Использованы существующий `update-web-desk.py` и принятая директива `manifest-src 'self'` из Caddy-фрагмента репозитория; перед применением сохранены закрытая копия Caddyfile и прежняя ссылка webroot, выполнен validate, после — validate/reload.

Проверено на публичном HTTPS:

- Все 25 файлов совпадают с main по размеру и SHA-256; `/connect/` отдаёт `no-store` и фактическую CSP с `manifest-src 'self'`.
- Manifest имеет MIME `application/manifest+json`, standalone и PNG 180×180; ссылка apple-touch-icon доступна.
- Chromium с мобильным viewport: обе ориентации без горизонтального переполнения, оба настоящих WSS-маршрута открываются, ошибок страницы нет. Кабинет получает bootstrap, session без входа — `401`.
- Остальные блоки Caddy совпадают побайтово. Image Caddy сохранён; ID всех остальных контейнеров, включая API/SMTP/hbbs/hbbr и другие проекты владельца, сохранены. API image не обновлялся, схема SQLite остаётся v4; миграция #71 не применялась.

Закрытая запись операции: `/opt/funtidesk-account/updates/phone-30fed457e87e/receipt.json`; прежние Caddyfile и ссылка — рядом. Штатный static helper также сохранил `updates/web-30fed457e87e/receipt.json`. Для отката вернуть прежний webroot, удалить только добавленную директиву manifest из desk-блока с проверкой текущего Caddyfile и пересоздать только Caddy прежним Compose с обоими override (`--no-deps --pull never`), затем validate/reload и HTTP-проверки. Остальные блоки, контейнеры и база не восстанавливаются и не изменяются. При расхождении с сохранённым состоянием сначала проверить параллельные изменения, не заменять общий Caddyfile вслепую.

Реальная приёмка #65 ещё нужна: Windows-компьютер и iPhone в Safari, запуск с «Домой», горизонтальное положение, русская клавиатура и диктовка. Проверка WSS подтверждает маршруты, но не заменяет настоящий удалённый сеанс с компьютером. Пароль для него по-прежнему обязателен; вход в кабинет не даёт доступа.
