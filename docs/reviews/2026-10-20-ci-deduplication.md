# Устранение дублей CI

Основа — main `d92eb80357eb`. В последних 100 workflow runs на 2026-10-20 найдены 29 пар одного head SHA/ветки с событиями push и pull_request. Интервал выборки: 18.10 18:37 — 20.10 12:27 МСК, граница выборки может обрезать старые пары. Время ниже — сумма elapsed времени jobs именно push-дубликатов (по started_at/completed_at), не billing GitHub и не ускорение одного PR. 26 запусков успешны, 3 отменены; время отменённых учтено до отмены.

| Workflow | Push-дубликаты | Runner-минуты |
|---|---:|---:|
| FuntiDesk CI | 16 | 72,0 |
| Browser client checks | 10 | 12,6 |
| Account checks | 3 | 40,6 |
| Всего | 29 | 125,1 |

Примеры проверяемых пар: общий [push 39400518680](https://github.com/michailr1/FuntiDesk/actions/runs/39400518680) / [PR 39400598332](https://github.com/michailr1/FuntiDesk/actions/runs/39400598332); браузер [push 39400518695](https://github.com/michailr1/FuntiDesk/actions/runs/39400518695) / [PR 39400597536](https://github.com/michailr1/FuntiDesk/actions/runs/39400597536); account [push 39286265113](https://github.com/michailr1/FuntiDesk/actions/runs/39286265113) / [PR 39286318654](https://github.com/michailr1/FuntiDesk/actions/runs/39286318654). Повторить измерение: GET repos/michailr1/FuntiDesk/actions/runs?per_page=100, группировка по name/head_sha/head_branch; для пар push+pull_request взять jobs push-запуска через actions/runs/{id}/jobs?per_page=100 и суммировать разности времён. Учитывать pagination при total_count>100 jobs. Будущая экономия зависит от частоты изменений, кэшей и длительности jobs; 125 минут не обещаются ежедневно.

Изменение только три workflow: push для main и всех пяти существующих интеграционных/публикующих/проверочных веток из текущих workflows (main, claude/rustdesk-fork-planning-324gyk и три michailr/m2/R21 ветки), плюс все теги. В обычных рабочих ветках автоматический запуск через PR (включая draft и synchronize); до PR — локально или workflow_dispatch. Ручной запуск добавлен общему/браузерному CI, account сохраняет прежний. Имена workflow/jobs, все jobs/шаги/команды, permissions и PR path filters побитово/структурно сохранены. Фильтры не ставятся на PR base-ветки, проверки fork PR остаются. Браузерный CI получил отмену только устаревшего запуска того же PR; main/tag/manual не отменяются этим новым правилом. Прежняя concurrency общего/account не меняется. Выпускающие Windows/Android/server workflows, монитор, код продукта и серверы не меняются.

Проверка конфигурации: YAML parsed с BaseLoader, полное структурное равенство jobs/permissions/PR trigger и push paths исходному main, сохранение integration/tag/manual; отдельный actionlint. Branch metadata сообщает protected=false, список rulesets пуст; административное чтение /branches/main/protection недоступно (403), настройки защиты не менялись. Имена check contexts сохранены независимо от этого.

Живая проверка: сначала создание PR, затем обновление его ветки; для каждого нового head должны быть только pull_request runs этих трёх workflow, без push. После merge ожидаются все три push-проверки main с прежними jobs. Доказательства и результаты добавляются в PR. Новых путей пропуска тестов/continue-on-error нет.

Откат: revert коммитов этого PR (или merge-коммита с -m 1) возвращает прежние три workflow. Для отмены изменение не требует поставки на desk или изменения секретов/защиты веток. До появления PR обычная рабочая ветка теперь не получает автоматический CI; это явный компромисс, компенсированный PR и ручным запуском.
