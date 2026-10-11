# FuntiDesk Web

Статический публичный сайт `desk.funti.cc`, основанный на утверждённом концепте «FuntiDesk · Живые соединения».

## Состав

- `index.html` — лендинг и интерактивные прототипы.
- `styles.css` — адаптивная светлая визуальная система и motion.
- `app.js` — локальные интерактивные сценарии семьи, P2P/Relay и Web-прототипа.
- `assets/funtidesk-mark.svg` — копия канонического бренд-знака C из `design/brand/funtidesk-mark.svg`.

Сайт не содержит backend, аналитики, cookies, внешних шрифтов или CDN-зависимостей. Его можно отдавать обычным Caddy `file_server` прямо из каталога `web/`.

## Проверка локально

```bash
python3 -m http.server 8080 -d web
```

Открыть `http://127.0.0.1:8080`.

## Production

Рекомендуемая схема: версионные директории `/opt/funtidesk-web/releases/<git-sha>/` + симлинк `/opt/funtidesk-web/current`. Caddy обслуживает только `/opt/funtidesk-web/current`; `hbbs/hbbr` и порты `21115–21117` не изменяются.

Перед переключением версии сохранять текущий Caddyfile и предыдущий target симлинка. После `caddy validate` выполнять только reload. Проверять HTTPS и доступность FuntiDesk server ports. Rollback — вернуть симлинк на предыдущую версию и reload Caddy.
