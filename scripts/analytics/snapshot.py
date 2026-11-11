#!/usr/bin/env python3
"""Закрытый агрегированный отчёт из согласованных SQLite-копий; без сети."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import html
import json
import os
import re
from pathlib import Path
import sqlite3
import time

DAY = 86400


@contextmanager
def database(path):
    path = Path(path).resolve(strict=True)
    if path.stat().st_size > 64 * 1024 * 1024:
        raise ValueError('snapshot exceeds 64 MiB')
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=1)
    deadline = time.monotonic() + 5
    db.set_progress_handler(lambda: time.monotonic() > deadline, 1000)
    try:
        db.execute('PRAGMA query_only=ON')
        db.execute('PRAGMA trusted_schema=OFF')
        db.execute('BEGIN')
        yield db
    finally:
        db.close()


def account_metrics(path, now):
    with database(path) as db:
        if db.execute('PRAGMA user_version').fetchone()[0] not in (4, 5):
            raise ValueError('unsupported account schema')
        scalar = lambda sql, args=(): db.execute(sql, args).fetchone()[0]
        result = {
            'accounts_existing': scalar('SELECT count(*) FROM accounts'),
            'accounts_enabled': scalar('SELECT count(*) FROM accounts WHERE disabled=0'),
            'account_bound_devices': scalar('SELECT count(DISTINCT pk) FROM devices'),
            'account_active_devices': {
                str(d): scalar('SELECT count(DISTINCT pk) FROM devices WHERE last_seen>? AND last_seen<=?',
                               (now - d * DAY, now)) for d in (1, 7, 30)},
            'account_active_accounts': {
                str(d): scalar('SELECT count(DISTINCT account_id) FROM devices WHERE last_seen>? AND last_seen<=?',
                               (now - d * DAY, now)) for d in (1, 7, 30)},
            'retained_reported_connections': {
                str(d): scalar('SELECT count(*) FROM connection_history WHERE connected_at>? AND connected_at<=?',
                               (now - d * DAY, now)) for d in (1, 7, 30)},
            'accounts_created_daily': list(db.execute(
                "SELECT date(created_at,'unixepoch'),count(*) FROM accounts WHERE created_at>? AND created_at<=? GROUP BY 1 ORDER BY 1",
                (now - 30 * DAY, now))),
            'retained_connections_daily': list(db.execute(
                "SELECT date(connected_at,'unixepoch'),count(*) FROM connection_history WHERE connected_at>? AND connected_at<=? GROUP BY 1 ORDER BY 1",
                (now - 30 * DAY, now))),
        }
        versions = {}
        for version, count in db.execute('SELECT version,count(*) FROM devices GROUP BY version'):
            label = version if re.fullmatch(r'[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:-ft\.[0-9]{1,6})?', version) else 'other_or_unknown'
            versions[label] = versions.get(label, 0) + count
        result['account_versions'] = versions
        return result


def hbbs_metrics(path):
    with database(path) as db:
        return {'hbbs_registered_ids': db.execute('SELECT count(*) FROM peer').fetchone()[0],
                'hbbs_distinct_nonempty_keys': db.execute(
                    'SELECT count(DISTINCT pk) FROM peer WHERE length(pk)>0').fetchone()[0]}


def collect(account=None, hbbs=None, now=None):
    now = int(time.time()) if now is None else now
    return {'observed_at_utc': datetime.fromtimestamp(now, timezone.utc).isoformat(),
            'account': account_metrics(account, now) if account else None,
            'hbbs': hbbs_metrics(hbbs) if hbbs else None,
            'unavailable': ['unique_people', 'installations', 'global_active_devices',
                            'connection_attempts', 'success_rate', 'p2p_ratio',
                            'connection_quality', 'platforms'],
            'limitations': 'Копии могут иметь разное время. Активность — только кабинет; история неполна, очищается и импортируется. Устройства и аккаунты не равны людям. Версии: допустимые номера, прочие объединены.'}


def render(report):
    return ('<!doctype html><html lang="ru"><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width">'
            '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'">'
            '<title>FuntiDesk Analytics</title><style>body{font:16px system-ui;max-width:960px;margin:40px auto;padding:20px}pre{white-space:pre-wrap}</style>'
            '<h1>FuntiDesk Analytics</h1><p>Закрытый локальный снимок. null — источник не предоставлен. '
            'Дневные ряды отражают оставшиеся записи, не полную историческую динамику.</p><pre>'
            + html.escape(json.dumps(report, ensure_ascii=False, indent=2)) + '</pre></html>')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account-copy')
    parser.add_argument('--hbbs-copy')
    parser.add_argument('--html', required=True, help='Новый закрытый файл вне webroot')
    args = parser.parse_args()
    if not args.account_copy and not args.hbbs_copy:
        parser.error('provide at least one consistent copy')
    os.umask(0o077)
    try:
        report = collect(args.account_copy, args.hbbs_copy)
        with open(args.html, 'x', encoding='utf-8') as output:
            output.write(render(report))
    except (OSError, ValueError, sqlite3.Error):
        parser.exit(1, 'Analytics failed: check snapshot, schema, limits and output path; no database details logged.\n')


if __name__ == '__main__':
    main()
