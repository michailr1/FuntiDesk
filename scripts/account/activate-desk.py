#!/usr/bin/env python3
"""Включить проверенный API и webroot только в desk-блоке Core Caddy."""
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import socket
import stat
import subprocess
import time
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


def request(url, status, expected, headers=None, timeout=10):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=timeout) as response:
            actual, body = response.status, response.read(65536)
    except urllib.error.HTTPError as error:
        actual, body = error.code, error.read(65536)
    if actual != status or expected not in body:
        raise RuntimeError('API readiness check failed')


def wait_ready(checks, timeout=45):
    deadline = time.monotonic() + timeout
    while True:
        try:
            for url, status, expected in checks:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError('HTTPS readiness deadline exceeded')
                request(url, status, expected, timeout=min(10, remaining))
            return
        except (OSError, urllib.error.URLError, RuntimeError) as error:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('HTTPS readiness deadline exceeded') from error
            time.sleep(min(1, remaining))


def verify_caddy(record, base, proposed):
    current = run('docker', 'ps', '--filter', 'label=com.docker.compose.project=caddy',
                  '--filter', 'label=com.docker.compose.service=caddy', '--format', '{{.ID}}').decode().split()
    if current != [record['caddyContainerBefore']]:
        raise RuntimeError('Live Caddy container changed after staging')
    info = json.loads(run('docker', 'inspect', current[0]))[0]
    if not info['State']['Running'] or info['Image'] != record['caddyImage']:
        raise RuntimeError('Live Caddy image or state changed after staging')
    config_hash = info.get('Config', {}).get('Labels', {}).get('com.docker.compose.config-hash')
    if not config_hash or run(*base, 'config', '--hash', 'caddy').decode().split() != ['caddy', config_hash]:
        raise RuntimeError('Base Compose differs from the live Caddy configuration')
    mounts = {item['Destination']: item for item in info['Mounts']}
    for target, source in [('/etc/caddy/Caddyfile', CADDY), ('/usr/share/caddy', CURRENT)]:
        mount = mounts.get(target, {})
        if (mount.get('Type') != 'bind' or mount.get('RW') is not False
                or Path(mount.get('Source', '/')).resolve() != source.resolve()):
            raise RuntimeError('Unexpected live Caddy bind mount')
    original_model = json.loads(run(*base, 'config', '--format', 'json'))
    original = original_model['services']['caddy']
    candidate_model = json.loads(run(*proposed, 'config', '--format', 'json'))
    candidate = candidate_model['services']['caddy']
    configured_mounts = {item['target']: item for item in original.get('volumes', [])}
    if not {'/etc/caddy/Caddyfile', '/usr/share/caddy', '/data'} <= configured_mounts.keys():
        raise RuntimeError('Compose omits a required live Caddy mount')
    for target, desired in configured_mounts.items():
        live = mounts.get(target, {})
        if (live.get('Type') != desired['type']
                or live.get('RW') is not (not desired.get('read_only', False))):
            raise RuntimeError('Compose changes a live Caddy mount')
        if desired['type'] == 'bind':
            if Path(live.get('Source', '/')).resolve() != Path(desired['source']).resolve():
                raise RuntimeError('Compose changes a live Caddy bind source')
        elif desired['type'] == 'volume':
            volume = original_model.get('volumes', {}).get(desired.get('source'), {})
            if not volume.get('name') or live.get('Name') != volume['name']:
                raise RuntimeError('Compose changes a live Caddy volume')
            if candidate_model.get('volumes', {}).get(desired['source']) != volume:
                raise RuntimeError('Caddy override changes an existing volume definition')
        else:
            raise RuntimeError('Unsupported Caddy mount type')
    ssl = next((item for item in original.get('volumes', []) if item['target'] == '/data'), {})
    ssl_volume = original_model.get('volumes', {}).get(ssl.get('source'), {}).get('name')
    if (ssl.get('type') != 'volume' or not ssl_volume
            or mounts.get('/data', {}).get('Name') != ssl_volume):
        raise RuntimeError('Compose would replace the live Caddy SSL volume')
    if ({key: value for key, value in original.items() if key != 'networks'}
            != {key: value for key, value in candidate.items() if key != 'networks'}):
        raise RuntimeError('Caddy override changes fields other than networks')
    old_networks, new_networks = original.get('networks', {}), candidate.get('networks', {})
    if (set(new_networks) != set(old_networks) | {'funtidesk-account-front'}
            # Compose renders a short network attachment as null and the same
            # explicit empty attachment as {}; both preserve default settings.
            or any((new_networks[name] or {}) != (settings or {})
                   for name, settings in old_networks.items())):
        raise RuntimeError('Caddy override changes existing networks')
    live_networks = info.get('NetworkSettings', {}).get('Networks', {})
    network_names = set()
    for logical_name in old_networks:
        definition = original_model.get('networks', {}).get(logical_name, {})
        if candidate_model.get('networks', {}).get(logical_name) != definition:
            raise RuntimeError('Caddy override changes an existing network definition')
        name = definition.get('name')
        if not name or name not in live_networks:
            raise RuntimeError('Compose changes a live Caddy network')
        network_names.add(name)
        network = json.loads(run('docker', 'network', 'inspect', name))[0]
        if network['Name'] != name or network['Id'] != live_networks[name]['NetworkID']:
            raise RuntimeError('Compose changes a live Caddy network identity')
    if network_names != set(live_networks):
        raise RuntimeError('Compose omits a live Caddy network')
    image = json.loads(run('docker', 'image', 'inspect', original['image']))[0]
    if image['Id'] != record['caddyImage']:
        raise RuntimeError('Compose would replace the staged Caddy image')


def private_request(image, path, status, expected, *, network='funtidesk-account-front', host='funtidesk-account'):
    # Diagnostic client joins the same internal frontend as the future proxy.
    payload = ('GET ' + path + ' HTTP/1.1\r\nHost: desk.funti.cc\r\nConnection: close\r\n\r\n').encode()
    with subprocess.Popen(['docker', 'run', '--rm', '-i', '--pull', 'never', '--network', network,
                           '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
                           '--entrypoint', '/bin/sh', image, '-c', 'nc -w 8 "$1" 21800', 'funti-private-http', host],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as client:
        try:
            client.stdin.write(payload)
            client.stdin.flush()
            # BusyBox nc needs stdin open to read, and may keep running after the
            # peer closes. Read the bounded response before sending stdin EOF.
            deadline = time.monotonic() + 15
            streams = [client.stdout, client.stderr]
            stdout = bytearray()
            stderr_size = 0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not streams:
                    raise RuntimeError('Private API readiness response incomplete')
                readable, _, _ = select.select(streams, [], [], remaining)
                for stream in readable:
                    chunk = os.read(stream.fileno(), 4096)
                    if not chunk:
                        streams.remove(stream)
                    elif stream is client.stdout:
                        stdout.extend(chunk)
                    else:
                        stderr_size += len(chunk)
                if len(stdout) > 65536 or stderr_size > 65536:
                    raise RuntimeError('Private API readiness response too large')
                if b'\r\n\r\n' in stdout:
                    head, body = bytes(stdout).split(b'\r\n\r\n', 1)
                    if (' ' + str(status) + ' ').encode() not in head.split(b'\r\n', 1)[0]:
                        raise RuntimeError('Private API readiness status mismatch')
                    if expected in body:
                        break
            client.stdin.close()
            client.stdin = None
            client.communicate(timeout=max(0.001, deadline - time.monotonic()))
        except BaseException:
            client.kill()
            client.communicate()
            raise
    if client.returncode:
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
    marker = ROOT / 'ACTIVATED'
    if marker.exists() or marker.is_symlink():
        raise RuntimeError('Activation marker already exists; inspect before retrying')
    marker_contents = json.dumps({
        'sourceCommit': record['sourceCommit'], 'binarySource': record['binarySource'],
        'webRelease': record['webRelease'],
    }, indent=2) + '\n'
    before = (stage / 'Caddyfile.before').read_bytes()
    candidate = (stage / 'Caddyfile.candidate').read_bytes()
    if hashlib.sha256(before).hexdigest() != record['caddyBeforeSha256']:
        raise RuntimeError('Original Caddy backup checksum mismatch')
    if hashlib.sha256(CADDY.read_bytes()).hexdigest() != record['caddyBeforeSha256']:
        raise RuntimeError('Live Caddy configuration changed after staging')
    if hashlib.sha256(candidate).hexdigest() != record['caddyCandidateSha256']:
        raise RuntimeError('Candidate checksum mismatch')
    if record.get('candidateValidated') is not True:
        raise RuntimeError('Staged Caddy candidate was not validated')
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
    verify_caddy(record, base, proposed)
    config_changed = link_changed = recreate_attempted = marker_attempted = False
    try:
        write_config(candidate)
        config_changed = True
        switch_link(record['webRelease'])
        link_changed = True
        # A failed/timed-out Compose call can already have replaced the container.
        recreate_attempted = True
        run(*proposed, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
        wait_ready([('https://desk.funti.cc/account/', 200, b'account.js'),
                    ('https://desk.funti.cc/api/account/v1/session', 401, b'authentication_required')])
        marker_attempted = True
        marker.write_text(marker_contents)
    except BaseException as activation_error:
        failures = []
        if config_changed:
            try:
                write_config(before)
            except BaseException:
                failures.append('Caddy configuration restore')
        if link_changed:
            try:
                switch_link(record['previousWebRoot'])
            except BaseException:
                failures.append('webroot restore')
        if recreate_attempted and not failures:
            try:
                run(*base, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
            except BaseException:
                failures.append('Caddy recreate')
        if (config_changed or link_changed) and not failures:
            try:
                if (hashlib.sha256(CADDY.read_bytes()).hexdigest() != record['caddyBeforeSha256']
                        or os.readlink(CURRENT) != record['previousWebRoot']):
                    raise RuntimeError('Restored Caddy files differ from staged originals')
                wait_ready([('https://desk.funti.cc/', 200, b'')])
            except BaseException:
                failures.append('rollback verification')
        if marker_attempted:
            try:
                marker.unlink(missing_ok=True)
            except BaseException:
                failures.append('activation marker removal')
        if failures:
            raise RuntimeError('Activation failed; rollback failed: ' + ', '.join(failures)) from activation_error
        raise
    print('DESK_ACCOUNT_ACTIVATED: HTTPS cabinet and private API verified')


if __name__ == '__main__':
    try:
        activate()
    except Exception as error:
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('DESK_ACTIVATION_FAILED: ' + reason)
        raise SystemExit(1)
