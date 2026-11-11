"""Приватный статический дашборд; только агрегаты, без JS и внешних ресурсов."""
from datetime import datetime, timedelta, timezone
from html import escape


def text(value):
    return escape(str(value), quote=True)


def number(value):
    return 'Нет данных' if value is None else f'{value:,}'.replace(',', ' ')


def daily(rows, now):
    """30 UTC-дат; первая и последняя могут быть неполными в исходной выборке."""
    values = dict(rows)
    return [((now.date() - timedelta(days=29-i)).isoformat(),
             values.get((now.date() - timedelta(days=29-i)).isoformat(), 0)) for i in range(30)]


def weekly(rows, now):
    values = dict(rows)
    def total(start):
        return sum(values.get((now.date() - timedelta(days=i)).isoformat(), 0)
                   for i in range(start, start+7))
    current, previous = total(1), total(8)
    change = current-previous
    return f'{number(current)} за 7 полных дней · {change:+d} к предыдущим 7 дням'


def chart(title, subtitle, rows, now, color, positive_only=True):
    if rows is None:
        return f'<article class="panel"><h2>{title}</h2><p>Источник не предоставлен</p></article>'
    points = daily(rows, now)
    if positive_only:
        points = [(day, n) for day, n in points if n > 0]
    if not points:
        return f'<article class="panel"><h2>{title}</h2><p>{subtitle}</p><strong class="comparison">{weekly(rows, now)}</strong><p>За последние 30 дней записей нет.</p></article>'
    ceiling = max(1, max(n for _, n in points))
    step = 600 / len(points)
    width = min(24, step * .6)
    bars = []
    for i, (day, n) in enumerate(points):
        height = n/ceiling*124
        bars.append(f'<rect x="{i*step+(step-width)/2+5:.2f}" y="{148-height:.2f}" width="{width:.2f}" height="{height:.2f}" rx="3" fill="{color}"><title>{day}: {n}</title></rect>')
    labels = (f'<text x="305" y="167" text-anchor="middle">{points[0][0][5:]}</text>' if len(points)==1 else
              f'<text x="8" y="167">{points[0][0][5:]}</text><text x="548" y="167">{points[-1][0][5:]}</text>')
    table = ''.join(f'<tr><td>{day}</td><td>{number(n)}</td></tr>' for day, n in points)
    return f'''<article class="panel"><div class="eyebrow">ПОСЛЕДНИЕ 30 ДАТ · UTC</div>
<h2>{title}</h2><p>{subtitle}</p><strong class="comparison">{weekly(rows, now)}</strong>
<svg viewBox="0 0 610 172" role="img" aria-label="{title}"><line x1="0" y1="149" x2="610" y2="149" stroke="#dfe6ed"/>
{''.join(bars)}{labels}
<text x="4" y="16">max {ceiling}</text></svg>
<details><summary>Числа по дням</summary><table><thead><tr><th>Дата UTC</th><th>Количество</th></tr></thead><tbody>{table}</tbody></table></details></article>'''


def render(report):
    now = datetime.fromisoformat(report['observed_at_utc'])
    updated = now.astimezone(timezone(timedelta(hours=3))).strftime('%d.%m.%Y, %H:%M МСК')
    account, hbbs = report.get('account'), report.get('hbbs')
    a, h = account or {}, hbbs or {}
    def metric(key, period=None):
        value = a.get(key)
        return value.get(str(period)) if period and value is not None else value
    cards = [
        ('Аккаунты', metric('accounts_existing'), 'Существующие аккаунты кабинета'),
        ('Активные устройства', metric('account_active_devices', 7), 'Обращались к кабинету за 7 дней'),
        ('Подключения в истории', metric('retained_reported_connections', 7), 'Сохранённые сообщения клиентов за 7 дней'),
        ('Ключи устройств hbbs', h.get('hbbs_distinct_nonempty_keys'), 'Уникальные непустые ключи регистраций'),
    ]
    tiles = ''.join(f'<article class="metric" aria-label="{title}"><span>{title}</span><strong>{number(value)}</strong><small>{hint}</small></article>' for title, value, hint in cards)
    periods = ''.join(f'<tr><th>{days} дн.</th><td>{number(metric("account_active_accounts", days))}</td><td>{number(metric("account_active_devices", days))}</td><td>{number(metric("retained_reported_connections", days))}</td></tr>' for days in (1, 7, 30))
    versions = a.get('account_versions', {})
    total = sum(versions.values())
    version_rows = ''.join(
        f'<div class="version"><div><span>{text("Другие / не определены" if v=="other_or_unknown" else v)}</span><strong>{number(n)} <small>· {n/total:.0%}</small></strong></div><meter min="0" max="{total}" value="{n}">{n} из {total}</meter></div>'
        for v, n in sorted(versions.items(), key=lambda item: (-item[1], item[0])) if total)
    if not version_rows:
        version_rows = '<p>Нет привязанных устройств</p>' if account is not None else '<p>Источник не предоставлен</p>'
    sources = ''.join(f'<li><span class="dot {"ok" if value is not None else "missing"}"></span>{name}: {"предоставлен" if value is not None else "нет данных"}</li>' for name, value in [('Кабинет', account), ('Регистрации hbbs', hbbs)])
    growth = chart('Новые аккаунты', 'Создания среди аккаунтов, оставшихся в базе. Нулевые дни скрыты.', a.get('accounts_created_daily') if account is not None else None, now, '#347aee')
    usage = chart('Сохранённые подключения', 'Сообщённые клиентами успешные исходящие подключения. Дни без сохранённых подключений скрыты.', a.get('retained_connections_daily') if account is not None else None, now, '#128c77', positive_only=True)
    registrations = chart('Новые регистрации ID', 'Первое создание текущих записей в hbbs; не число установок или людей. Нулевые дни скрыты.', h.get('registered_ids_daily'), now, '#8a64d5')
    return f'''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>FuntiDesk Analytics</title><style>{STYLE}</style></head><body>
<header><a class="brand" href="#overview"><span class="logo">F</span>FuntiDesk <span>Analytics</span></a><span class="private">Закрытая статистика</span></header>
<main id="overview"><div class="heading"><div><div class="eyebrow">ИСПОЛЬЗОВАНИЕ И РАЗВИТИЕ</div><h1>Обзор проекта</h1><p>Что растёт, что используется и какие данные уже доступны.</p></div>
<div class="updated">Снимок данных<strong>{text(updated)}</strong><small>Обновление раз в сутки · окно 30 дней</small></div></div>
<div class="notice">Аккаунты и устройства — разные показатели. Они не означают количество людей.</div>
<section class="metrics" aria-label="Основные показатели">{tiles}</section>
<section class="grid" aria-label="Динамика">{growth}{registrations}</section>
<section class="history" aria-label="Подключения">{usage}</section>
<section class="grid"><article class="panel"><div class="eyebrow">АКТИВНОСТЬ КАБИНЕТА</div><h2>За день, неделю и месяц</h2><p>Скользящие окна от момента снимка. Активность — обращения к кабинету.</p>
<div class="table-scroll"><table><thead><tr><th>Период</th><th>Аккаунты</th><th>Устройства</th><th>История</th></tr></thead><tbody>{periods}</tbody></table></div>
<div class="footnote">Привязано устройств: {number(metric('account_bound_devices'))} · Включено аккаунтов: {number(metric('accounts_enabled'))}. Полная активность клиентов без аккаунта здесь не видна.</div></article>
<article class="panel"><div class="eyebrow">СОСТАВ АУДИТОРИИ</div><h2>Версии клиентов</h2><p>Последняя сообщённая версия каждого привязанного устройства.</p>{version_rows}</article></section>
<section class="panel limits"><div><div class="eyebrow">ЧТО ПОКА НЕ ИЗМЕРЯЕТСЯ</div><h2>Качество связи и вся аудитория</h2><p>Нет данных о доле P2P/relay, успешности попыток, платформах, установках и уникальных людях. Это не нулевые значения.</p></div>
<div class="footnote">Для этих показателей нужен отдельный источник событий. Новая клиентская телеметрия не включена.</div></section>
<footer class="panel"><h2>Как читать эти числа</h2><ul>{sources}</ul><p>Регистраций ID в hbbs: {number(h.get('hbbs_registered_ids'))}. Этот счётчик нельзя складывать с устройствами кабинета.</p>
<p>Графики — текущий срез сохранённых записей: удаление аккаунта, импорт и очистка истории меняют прошлые дни. История ограничена 90 днями и 1000 записями на аккаунт. Это не полный журнал всех сеансов.</p>
<p>График регистраций ID использует created_at текущих записей hbbs; смена ID в существующей записи сохраняет прежнюю дату. На дневных графиках показаны только ненулевые даты; календарные границы сравнения недель не меняются.</p>
<p>Сравнение недель использует полные календарные дни UTC, без сегодняшнего дня. Крайние даты графиков могут быть неполными. Нули означают отсутствие сохранённых записей, а не доказательство отсутствия использования.</p>
<p>Время выше — момент вычисления отчёта. Копии источников снимаются последовательно; историческая DAU и удержание из одного last_seen не восстанавливаются.</p></footer>
</main><div class="end">FuntiDesk · Без содержимого сеансов, файлов и экранов</div></body></html>'''


STYLE = '''
:root{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#172c42;background:#f3f6fa;font-size:15px}
*{box-sizing:border-box}body{margin:0}header{background:#112a43;color:white;padding:22px max(24px,calc((100% - 1220px)/2));display:flex;align-items:center;justify-content:space-between;gap:18px}
a{color:inherit;text-decoration:none}.brand{font-size:18px;font-weight:700;display:flex;align-items:center;gap:10px}.brand>span:last-child{font-weight:400;color:#a9c1d9}.logo{background:#42c8aa;color:#112a43;border-radius:9px;padding:4px 10px}.private{font-size:12px;color:#b7cee1;border:1px solid #3d546b;border-radius:20px;padding:6px 12px}
main{max-width:1268px;margin:auto;padding:36px 24px}.heading{display:flex;justify-content:space-between;align-items:center;gap:20px;margin-bottom:22px}.eyebrow{font-size:10px;letter-spacing:1.6px;font-weight:700;color:#637b92}h1{font-size:36px;letter-spacing:-1.3px;margin:9px 0}h2{font-size:20px;letter-spacing:-.4px;margin:8px 0 10px}p{color:#5c7085;line-height:1.6;margin:8px 0}.updated{text-align:right;color:#637b92;font-size:12px;line-height:1.7}.updated strong,.updated small{display:block}.updated strong{font-size:14px;color:#172c42}.notice{background:#e7eef7;border-radius:9px;padding:12px 16px;color:#405a75;font-size:13px;margin-bottom:22px}
.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:16px;margin-bottom:22px}.metric,.panel{background:white;border:1px solid #e1e8ef;border-radius:14px;box-shadow:0 2px 4px #112a4303}.metric{padding:22px;display:flex;flex-direction:column;gap:10px}.metric>span{font-size:13px;color:#5c7085}.metric>strong{font-size:36px;line-height:1.1;letter-spacing:-1px}.metric small{color:#637b92;line-height:1.5;font-size:11px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:22px;margin-bottom:22px}.panel{padding:26px;min-width:0}.panel p{font-size:13px}.comparison{display:block;font-size:13px;color:#2f577b;margin:18px 0 0}.history{margin-bottom:22px}svg{display:block;width:100%;height:auto;max-height:220px;margin:16px 0 8px}svg text{font:10px system-ui;fill:#667d92}details{font-size:12px;margin-top:12px}summary{cursor:pointer;color:#426994}table{width:100%;border-collapse:collapse;text-align:left;font-size:13px;font-variant-numeric:tabular-nums}th{font-weight:600;color:#637b92}td,th{padding:12px 8px;border-bottom:1px solid #edf1f5}td:not(:first-child),th:not(:first-child){text-align:right}details table{font-size:12px}.table-scroll{overflow-x:auto}.footnote{font-size:12px;line-height:1.7;color:#637b92;margin-top:20px}.version{margin:20px 0}.version>div{display:flex;justify-content:space-between;gap:16px;font-size:13px}.version small{color:#637b92;font-weight:400}meter{width:100%;height:10px;margin-top:8px;accent-color:#347aee}meter::-webkit-meter-bar{background:#edf1f7;border:0}meter::-webkit-meter-optimum-value{background:#347aee;border-radius:8px}.limits{margin-bottom:22px;display:grid;grid-template-columns:2fr 1fr;gap:30px;background:#edf3f8}.end{text-align:center;color:#72869a;font-size:11px;padding:0 24px 32px}footer ul{display:flex;gap:25px;list-style:none;padding:0;font-size:12px;color:#536b81}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:7px}.ok{background:#148e77}.missing{background:#ad7b24}
@media(max-width:900px){.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}.grid{grid-template-columns:1fr}.limits{grid-template-columns:1fr;gap:0}}
@media(max-width:540px){header{padding:18px;flex-wrap:wrap}.private{font-size:10px}main{padding:24px 14px}.heading{align-items:flex-start;flex-direction:column}.updated{text-align:left}h1{font-size:30px}.metrics{gap:10px}.metric{padding:17px 13px}.metric>strong{font-size:28px}.panel{padding:20px}.grid{gap:16px}footer ul{flex-wrap:wrap;gap:12px}}
'''
