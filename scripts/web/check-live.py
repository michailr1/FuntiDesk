#!/usr/bin/env python3
"""Сверить сайт desk.funti.cc с main: публичные файлы и версию API кабинета.

Печатает отчёт в Markdown. Код выхода: 0 — совпадает, 10 — расхождения,
1 — сбой самой проверки. Только чтение публичных адресов, без входа.
"""
import hashlib
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request

HOST = 'https://desk.funti.cc'
ROOT = Path(__file__).resolve().parents[2]
# Адреса API, которые в main уже есть: без входа они отвечают 401, а на старом
# API — 404. Пополнять при каждом новом адресе кабинета.
API_ROUTES = [
    ('POST', '/api/account/v1/family/remove/cancel', 'отмена удаления (#71, схема v5)'),
]


def fetch(method, path, data=None):
    req = urllib.request.Request(HOST + path, data=data, method=method,
                                 headers={'User-Agent': 'FuntiDesk site check',
                                          'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b''


def main():
    manifest = json.loads((ROOT / 'web/manifest.json').read_text())['artifacts']
    stale, missing = [], []
    for item in manifest:
        status, body = fetch('GET', '/' + item['file'])
        if status != 200:
            missing.append(f"`{item['file']}` — HTTP {status}")
        elif hashlib.sha256(body).hexdigest() != item['sha256']:
            stale.append(f"`{item['file']}`")
    api = []
    for method, path, what in API_ROUTES:
        status, _ = fetch(method, path, b'{}')
        if status == 404:
            api.append(f"`{method} {path}` — 404, адреса нет: {what}")
        elif status not in (401, 403):
            api.append(f"`{method} {path}` — HTTP {status}, ожидалось 401: {what}")
    print('# Сайт desk.funti.cc и main\n')
    print(f'Проверено файлов: {len(manifest)}, адресов API: {len(API_ROUTES)}.\n')
    if not (stale or missing or api):
        print('Всё совпадает.')
        return 0
    if stale:
        print('Отличаются от `web/manifest.json` в main (не выложены или изменены на сервере):\n')
        print('\n'.join(f'- {x}' for x in stale) + '\n')
    if missing:
        print('Нет на сервере:\n')
        print('\n'.join(f'- {x}' for x in missing) + '\n')
    if api:
        print('API кабинета отстаёт от main:\n')
        print('\n'.join(f'- {x}' for x in api) + '\n')
    print('Выложить по `docs/ACCOUNT_DEPLOYMENT.md`. Сразу после вливания расхождение ожидаемо: эта задача — напоминание, что выкладка ещё не сделана.')
    return 10


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 — the check itself failed
        print(f'Проверка не выполнена: {type(e).__name__}: {e}')
        sys.exit(1)
