# Закрытая статистика FuntiDesk (ADR-019, #115)

Отчёт по агрегатам кабинета и hbbs, открывается на `https://desk.funti.cc/<закрытый путь>/` по логину и паролю. Порядок выкладки — `docs/ACCOUNT_DEPLOYMENT.md`, раздел «Статистика».

- `analytics.caddy.template` — защищённый `handle` для блока `desk.funti.cc`; рабочий файл с путём и хэшем создаётся на сервере, в репозиторий не попадает.
- `caddy-analytics.override.yaml` — два монтирования только для чтения в общий Caddy.
- `funtidesk-analytics.service`, `.timer` — ежедневное обновление отчёта `scripts/analytics/publish.py`.
