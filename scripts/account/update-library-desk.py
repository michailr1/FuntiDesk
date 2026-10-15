#!/usr/bin/env python3
"""Prepare pinned API images; --apply upgrades the active v2 cabinet without reinitializing it."""
import argparse
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]
ROOT = Path('/opt/funtidesk-account')
CURRENT = Path('/opt/funtidesk-web/current')


def load(name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts/account' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args):
    p = subprocess.run(args, capture_output=True, timeout=120)
    if p.returncode:
        raise RuntimeError('Library update operation failed: ' + args[0])
    return p.stdout


def private_file(path, contents):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(contents)
        output.flush()
        os.fsync(output.fileno())


def image_env(data, image):
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image):
        raise RuntimeError('Expected a verified immutable API image')
    lines = data.splitlines(keepends=True)
    if sum(line.startswith(b'FUNTI_ACCOUNT_IMAGE=') for line in lines) != 1:
        raise RuntimeError('Expected exactly one API image setting')
    return b''.join(b'FUNTI_ACCOUNT_IMAGE=' + image.encode() + (b'\r\n' if line.endswith(b'\r\n') else b'\n') if line.startswith(b'FUNTI_ACCOUNT_IMAGE=') else line for line in lines)


def database_version(path):
    connection = sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True)
    try:
        return connection.execute('PRAGMA user_version').fetchone()[0]
    finally:
        connection.close()


def stage_full_web(release):
    rows = json.loads((REPO / 'web/manifest.json').read_text())['artifacts']
    checked = []
    for row in rows:
        path = Path(row['file'])
        if path.is_absolute() or '..' in path.parts or (REPO / 'web' / path).is_symlink():
            raise RuntimeError('Unsafe public web path')
        data = (REPO / 'web' / path).read_bytes()
        if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
            raise RuntimeError('Web checksum mismatch')
        checked.append((path, data))
    release.mkdir(mode=0o755)
    for path, data in checked:
        target = release / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o444)
    (release / 'manifest.json').write_text(json.dumps({'artifacts': rows}, indent=2) + '\n')


def api_ready(ip):
    for path, expected in [('/health', 200), ('/api/account/v1/session', 401), ('/api/account/v1/library', 401)]:
        connection = http.client.HTTPConnection(ip, 21800, timeout=4)
        try:
            connection.request('GET', path, headers={'Host': 'desk.funti.cc'})
            response = connection.getresponse()
            if response.status != expected:
                raise RuntimeError('Compatible API readiness failed')
            response.read()
        finally:
            connection.close()


def update(archive, apply):
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc' or not (ROOT / 'ACTIVATED').is_file():
        raise RuntimeError('Library update requires the active Core cabinet')
    if run('git', '-C', str(REPO), 'status', '--porcelain').strip():
        raise RuntimeError('Source must be clean')
    pin = json.loads((REPO / 'infra/funtidesk-account/account-library-release.json').read_text())
    source = run('git', '-C', str(REPO), 'rev-parse', 'HEAD').decode().strip()
    directory = ROOT / 'updates' / ('library-' + pin['source'][:12])
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    prepare = load('prepare-desk')
    prepare.RELEASE = pin
    verified = directory / 'verified'
    if not (directory / 'PREPARED').exists():
        verified.mkdir(mode=0o700)
        prepare.verify_archive(archive, verified)
        qualified = prepare.source_qualified_archive(verified)
        run('docker', 'load', '--input', str(qualified))
    else:
        if prepare.digest(archive) != pin['artifact_zip_sha256']:
            raise RuntimeError('Prepared archive changed')
    image = json.loads(run('docker', 'image', 'inspect', 'funtidesk-account:' + pin['source'][:12]))[0]
    if image['Id'] not in [pin['images']['funtidesk-account'], pin['oci_images']['funtidesk-account']] or image['Config']['Labels']['org.opencontainers.image.revision'] != pin['source'] or image['Config']['User'] != '10001:10001':
        raise RuntimeError('Prepared API image identity mismatch')
    if not (directory / 'PREPARED').exists():
        private_file(directory / 'PREPARED', json.dumps({'source': pin['source'], 'image': image['Id']}).encode())
    if not apply:
        print('DESK_LIBRARY_API_PREPARED')
        return
    if (directory / 'APPLY_STARTED').exists():
        raise RuntimeError('An API upgrade was already attempted; inspect receipts before retrying')
    before = json.loads(run('docker', 'inspect', 'funtidesk-account-account-1'))[0]
    previous = json.loads((REPO / 'infra/funtidesk-account/account-api-release.json').read_text())
    if before['Image'] not in [previous['images']['funtidesk-account'], previous['oci_images']['funtidesk-account']]:
        raise RuntimeError('Expected the existing verified MIME API')
    data = next(Path(m['Source']) for m in before['Mounts'] if m['Destination'] == '/data')
    database = data / 'account.sqlite3'
    if database_version(database) != 2:
        raise RuntimeError('This update only migrates an existing v2 database')
    if not (ROOT / 'integration/caddy-web-client.override.yaml').is_file():
        raise RuntimeError('Expected the checked browser Caddy overlay')
    account = ['docker', 'compose', '-p', 'funtidesk-account', '--env-file', str(ROOT / 'account.env'), '-f', str(REPO / 'infra/funtidesk-account/compose.yaml')]
    caddy = ['docker', 'compose', '-p', 'caddy', '--env-file', str(ROOT / 'account.env'), '-f', '/opt/remnawave/caddy/docker-compose.yml', '-f', str(ROOT / 'integration/caddy-account.override.yaml'), '-f', str(ROOT / 'integration/caddy-web-client.override.yaml')]
    caddy_ids = run('docker', 'ps', '-q', '--filter', 'label=com.docker.compose.project=caddy', '--filter', 'label=com.docker.compose.service=caddy').decode().split()
    if len(caddy_ids) != 1:
        raise RuntimeError('Expected one active Caddy')
    old_caddy = json.loads(run('docker', 'inspect', caddy_ids[0]))[0]
    if run(*caddy, 'config', '--hash', 'caddy').decode().split() != ['caddy', old_caddy['Config']['Labels']['com.docker.compose.config-hash']]:
        raise RuntimeError('Compose differs from live Caddy')
    old_env = (ROOT / 'account.env').read_bytes()
    next_env = image_env(old_env, image['Id'])
    old_link = os.readlink(CURRENT)
    release = Path('/opt/funtidesk-web/releases') / (source + '-account-sync')
    stage_full_web(release)
    (release / 'SOURCE_COMMIT').write_text(source + '\n')
    protected = [ROOT / 'secrets/account.key', ROOT / 'secrets/witness.key', ROOT / 'secrets/funtidesk202610.private', Path('/opt/funtidesk/data/id_ed25519'), Path('/opt/funtidesk/data/id_ed25519.pub')]
    hashes = {p: hashlib.sha256(p.read_bytes()).digest() for p in protected}
    state = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
    stable = {v['Name']: v['Id'] for v in state if v['Id'] not in [before['Id'], old_caddy['Id']]}
    run('python3', '-B', str(REPO / 'scripts/account/probe-witness-head.py'))
    if (ROOT / 'account.env').read_bytes() != old_env or os.readlink(CURRENT) != old_link:
        raise RuntimeError('Live state changed during preparation')
    private_file(directory / 'account.env.before', old_env)
    private_file(directory / 'account.env.next', next_env)
    private_file(directory / 'APPLY_STARTED', source.encode())
    switched = False
    activation = load('activate-desk')
    try:
        os.replace(directory / 'account.env.next', ROOT / 'account.env')
        run(*account, 'up', '-d', '--no-deps', '--pull', 'never', 'account')
        deadline = time.monotonic() + 45
        while True:
            try:
                api_ready(before['NetworkSettings']['Networks']['funtidesk-account-front']['IPAddress'])
                break
            except (OSError, RuntimeError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('API v3 did not become ready')
                time.sleep(1)
        if database_version(database) != 3:
            raise RuntimeError('Expected the completed v3 migration')
        run('python3', '-B', str(REPO / 'scripts/account/probe-witness-head.py'))
        activation.switch_link(str(release))
        switched = True
        run(*caddy, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
        activation.wait_ready([('https://desk.funti.cc/', 200, b'FuntiDesk'), ('https://desk.funti.cc/account/', 200, b'favorites-title'), ('https://desk.funti.cc/connect/', 200, b'connection-form'), ('https://desk.funti.cc/api/account/v1/library', 401, b'authentication_required')])
        after = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
        assert {v['Name']: v['Id'] for v in after if v['Name'] in stable} == stable
        assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in hashes.items())
        assert (ROOT / 'account.env').read_bytes() == next_env
        new_api = next(v for v in after if v['Name'] == '/funtidesk-account-account-1')
        assert new_api['Image'] == image['Id'] and new_api['RestartCount'] == 0 and not new_api['HostConfig']['PortBindings']
        new_caddy = next(v for v in after if v['Config'].get('Labels', {}).get('com.docker.compose.project') == 'caddy')
        assert new_caddy['Image'] == old_caddy['Image']
        assert {m['Destination']: (m.get('Name'), m['RW']) for m in new_caddy['Mounts']} == {m['Destination']: (m.get('Name'), m['RW']) for m in old_caddy['Mounts']}
        receipt = {'apiSource': pin['source'], 'toolsAndWebSource': source, 'apiImage': image['Id'], 'previousApiImage': before['Image'], 'artifactRun': pin['run_id'], 'artifactId': pin['artifact_id'], 'zipSha256': pin['artifact_zip_sha256'], 'databaseVersion': 3, 'databaseInitialized': False, 'restorePerformed': False, 'keysAndNamespacePreserved': True, 'otherContainersPreserved': True, 'webroot': str(release), 'previousWebroot': old_link, 'windowsAcceptance': False}
        private_file(ROOT / 'integration/api-library-update.json', json.dumps(receipt, indent=2).encode())
        print('DESK_LIBRARY_API_WEB_READY')
    except Exception:
        if switched:
            activation.switch_link(old_link)
            run(*caddy, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
        # Never open a migrated database with the old v2 binary or roll back witness state.
        if database_version(database) == 2:
            private_file(directory / 'account.env.rollback', old_env)
            os.replace(directory / 'account.env.rollback', ROOT / 'account.env')
            run(*account, 'up', '-d', '--no-deps', '--pull', 'never', 'account')
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        update(args.archive, args.apply)
    except Exception as error:
        print('DESK_LIBRARY_UPDATE_FAILED: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__))
        raise SystemExit(1)
