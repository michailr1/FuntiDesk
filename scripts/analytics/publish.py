#!/usr/bin/env python3
"""Обновить закрытый отчёт аналитики на сервере (ADR-019, #115).

Снимает согласованные копии рабочих SQLite через backup API (WAL-безопасно,
без записи в источник), считает агрегаты scripts/analytics/snapshot.py и
атомарно заменяет index.html в каталоге отчёта. Копии удаляются сразу.
Ошибка аналитики не трогает account, hbbs и Caddy: старый отчёт остаётся.
"""
import argparse
import os
from pathlib import Path
import sqlite3
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import snapshot  # noqa: E402


def consistent_copy(source, target):
    source = Path(source).resolve(strict=True)
    src = sqlite3.connect(source.as_uri() + '?mode=ro', uri=True, timeout=5)
    try:
        dst = sqlite3.connect(target)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()


def publish(account, hbbs, out_dir):
    out_dir = Path(out_dir)
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='funtidesk-analytics-') as work:
        copies = {}
        for name, source in (('account', account), ('hbbs', hbbs)):
            if source:
                copies[name] = Path(work) / f'{name}.sqlite'
                consistent_copy(source, copies[name])
        report = snapshot.collect(copies.get('account'), copies.get('hbbs'))
    page = snapshot.render(report)
    fd, tmp = tempfile.mkstemp(prefix='.index-', suffix='.html', dir=out_dir)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(page)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, out_dir / 'index.html')
    except BaseException:
        os.unlink(tmp)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account-db', help='рабочая база кабинета')
    parser.add_argument('--hbbs-db', help='рабочая база hbbs')
    parser.add_argument('--out-dir', required=True, help='каталог отчёта вне общего webroot')
    args = parser.parse_args()
    if not args.account_db and not args.hbbs_db:
        parser.error('нужен хотя бы один источник')
    try:
        publish(args.account_db, args.hbbs_db, args.out_dir)
    except (OSError, ValueError, sqlite3.Error) as e:
        # Только класс ошибки: путь, SQL и данные в журнал не попадают.
        parser.exit(1, f'Analytics publish failed: {type(e).__name__}; the previous report is kept.\n')


if __name__ == '__main__':
    main()
