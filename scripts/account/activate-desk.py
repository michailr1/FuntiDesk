#!/usr/bin/env python3
"""Включить проверенный API и webroot только в desk-блоке Core Caddy."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import subprocess
import urllib.error
import urllib.request
import uuid

ROOT = Path('/opt/funtidesk-account')
CADDY = Path('/opt/remnawave/caddy/Caddyfile')
CURRENT = Path('/opt/funtidesk-web/current')
BASE = Path('/opt/remnawave/caddy/docker-compose.yml')


def run(*args):
    result = subprocess.run(args, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError('Activation operation failed: ' + args[0])
    return result.stdout


def request(url, status, expected, headers=None):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=10) as response:
            actual, body = response.status, response.read(65536)
    except urllib.error.HTTPError as error:
        actual, body = error.code, error.read(65536)
    if actual != status or expected not in body:
        raise RuntimeError('API readiness check failed')


def private_request(image, path, status, expected):
    # Diagnostic client joins the same internal frontend as the future proxy.
    payload = ('GET ' + path + ' HTTP/1.1\r\nHost: desk.funti.cc\r\nConnection: close\r\n\r\n').encode()
    result = subprocess.run(['docker', 'run', '--rm', '-i', '--network', 'funtidesk-account-front',
                             '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                             '--entrypoint', '/bin/sh', image, '-c', 'nc -w 8 funtidesk-account 21800'],
                            input=payload, capture_output=True, timeout=15)
    if result.returncode or (' ' + str(status) + ' ').encode() not in result.stdout.split(b'\r\n', 1)[0] or expected not in result.stdout:
        raise RuntimeError('Private API readiness check failed')


def switch_link(target):
    temporary = CURRENT.parent / ('.current-account-' + uuid.uuid4().hex)
    temporary.symlink_to(target)
    os.replace(temporary, CURRENT)


def write_config(contents):
    temporary = CADDY.parent / ('.Caddyfile-account-' + uuid.uuid4().hex)
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, stat.S_IMODE(CADDY.stat().st_mode))
    with os.fdopen(descriptor, 'wb') as output:
        output.write(contents)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, CADDY)


def activate():
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc':
        raise RuntimeError('Activation must run as root on Core')
    stage = ROOT / 'integration'
    record = json.loads((stage / 'stage.json').read_text())
    before = (stage / 'Caddyfile.before').read_bytes()
    candidate = (stage / 'Caddyfile.candidate').read_bytes()
    if hashlib.sha256(CADDY.read_bytes()).hexdigest() != record['caddyBeforeSha256']:
        raise RuntimeError('Live Caddy configuration changed after staging')
    if hashlib.sha256(candidate).hexdigest() != record['caddyCandidateSha256']:
        raise RuntimeError('Candidate checksum mismatch')
    if os.readlink(CURRENT) != record['previousWebRoot']:
        raise RuntimeError('Live webroot changed after staging')
    if not (ROOT / 'data/account.sqlite3').is_file():
        raise RuntimeError('Account database is not initialized')
    identity = ROOT / 'identity/hbbs.sock'
    if not identity.exists() or not stat.S_ISSOCK(identity.stat().st_mode):
        raise RuntimeError('Private hbbs resolver socket is absent')
    private_request(record['caddyImage'], '/health', 200, b'ok')
    private_request(record['caddyImage'], '/api/account/v1/session', 401, b'authentication_required')
    dns = json.loads((ROOT / 'dns-records.json').read_text())
    for name, expected in dns.items():
        records = [''.join(shlex.split(line)) for line in run('dig', '+short', 'TXT', expected['name']).decode().splitlines()]
        if expected['value'] not in records or (name == 'SPF' and sum(r.startswith('v=spf1 ') for r in records) != 1):
            raise RuntimeError('Production ' + name + ' DNS is not ready')
    base = ['docker', 'compose', '-p', 'caddy']
    if (BASE.parent / '.env').is_file():
        base += ['--env-file', str(BASE.parent / '.env')]
    base += ['--env-file', str(ROOT / 'account.env'), '-f', str(BASE)]
    proposed = [*base, '-f', str(stage / 'caddy-account.override.yaml')]
    run(*proposed, 'config', '--quiet')
    try:
        write_config(candidate)
        switch_link(record['webRelease'])
        run(*proposed, 'up', '-d', '--no-deps', '--force-recreate', 'caddy')
        request('https://desk.funti.cc/account/', 200, b'account.js')
        request('https://desk.funti.cc/api/account/v1/session', 401, b'authentication_required')
    except Exception:
        write_config(before)
        switch_link(record['previousWebRoot'])
        run(*base, 'up', '-d', '--no-deps', '--force-recreate', 'caddy')
        raise
    (ROOT / 'ACTIVATED').write_text(record['sourceCommit'] + '\n')
    print('DESK_ACCOUNT_ACTIVATED: HTTPS cabinet and private API verified')


if __name__ == '__main__':
    try:
        activate()
    except Exception as error:
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('DESK_ACTIVATION_FAILED: ' + reason)
        raise SystemExit(1)
