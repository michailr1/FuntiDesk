#!/usr/bin/env python3
"""Prepare a pinned Core-only API; --apply preserves the existing database and removes the witness relay."""
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


def load(name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts/account' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args):
    p = subprocess.run(args, capture_output=True, timeout=120)
    if p.returncode:
        raise RuntimeError('Account API update operation failed: ' + args[0])
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


def local_env(data, image):
    lines = image_env(data, image).splitlines(keepends=True)
    return b''.join(line for line in lines if not line.startswith((b'FUNTI_ACCOUNT_WITNESS_', b'FUNTI_ACCOUNT_RECOVERY_DIRECTORY=', b'FUNTI_WITNESS_')))


def content_hashes(connection):
    names = [r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name!='recovery_state' ORDER BY name")]
    return {name: hashlib.sha256(repr(connection.execute('SELECT * FROM "' + name.replace('"', '""') + '" ORDER BY rowid').fetchall()).encode()).hexdigest() for name in names}


def backup_and_check(database, directory, source='HEAD'):
    migration = run('git', '-C', str(REPO), 'show', source + ':account/src/schema-local.sql').decode()
    original = sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True)
    try:
        before = content_hashes(original)
        for name in ['account.sqlite3.before', 'migration-preview.sqlite3']:
            path = directory / name
            private_file(path, b'')
            copy = sqlite3.connect(path)
            try:
                original.backup(copy)
                if name.startswith('migration-'):
                    copy.executescript(migration)
                    if content_hashes(copy) != before or copy.execute('PRAGMA user_version').fetchone()[0] != 4:
                        raise RuntimeError('Migration changed application data')
                if copy.execute('PRAGMA integrity_check').fetchall() != [('ok',)] or copy.execute('PRAGMA foreign_key_check').fetchall():
                    raise RuntimeError('Backup or migration integrity failed')
            finally:
                copy.close()
        return before
    finally:
        original.close()


def update(archive, apply):
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc' or not (ROOT / 'ACTIVATED').is_file():
        raise RuntimeError('API update requires the active Core cabinet')
    if run('git', '-C', str(REPO), 'status', '--porcelain').strip():
        raise RuntimeError('Source must be clean')
    pin = json.loads((REPO / 'infra/funtidesk-account/account-release.json').read_text())
    source = run('git', '-C', str(REPO), 'rev-parse', 'HEAD').decode().strip()
    directory = ROOT / 'updates' / ('local-api-' + pin['source'][:12])
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    prepare = load('prepare-desk')
    prepare.RELEASE = pin
    if not (directory / 'PREPARED').exists():
        verified = directory / 'verified'
        verified.mkdir(mode=0o700)
        prepare.verify_archive(archive, verified)
        run('docker', 'load', '--input', str(prepare.source_qualified_archive(verified)))
    elif prepare.digest(archive) != pin['artifact_zip_sha256']:
        raise RuntimeError('Prepared archive changed')
    image = json.loads(run('docker', 'image', 'inspect', 'funtidesk-account:' + pin['source'][:12]))[0]
    if image['Id'] not in [pin['images']['funtidesk-account'], pin['oci_images']['funtidesk-account']] or image['Config']['Labels']['org.opencontainers.image.revision'] != pin['source'] or image['Config']['User'] != '10001:10001':
        raise RuntimeError('Prepared API image identity mismatch')
    if not (directory / 'PREPARED').exists():
        private_file(directory / 'PREPARED', json.dumps({'source': pin['source'], 'image': image['Id']}).encode())
    if not apply:
        print('DESK_LOCAL_API_PREPARED')
        return
    if (directory / 'APPLY_STARTED').exists():
        raise RuntimeError('An API update was already attempted; inspect receipts before retrying')
    before = json.loads(run('docker', 'inspect', 'funtidesk-account-account-1'))[0]
    previous = json.loads((REPO / 'infra/funtidesk-account/account-library-release.json').read_text())
    if before['Image'] not in [previous['images']['funtidesk-account'], previous['oci_images']['funtidesk-account']]:
        raise RuntimeError('Expected the existing v3 API image')
    data = next(Path(m['Source']) for m in before['Mounts'] if m['Destination'] == '/data')
    database = data / 'account.sqlite3'
    if database_version(database) != 3:
        raise RuntimeError('This update migrates the existing v3 database')
    compose = ['docker', 'compose', '-p', 'funtidesk-account', '--env-file', str(ROOT / 'account.env'), '-f', str(REPO / 'infra/funtidesk-account/compose.yaml')]
    old_env = (ROOT / 'account.env').read_bytes()
    next_env = local_env(old_env, image['Id'])
    protected = [ROOT / 'secrets/account.key', ROOT / 'secrets/funtidesk202610.private', Path('/opt/funtidesk/data/id_ed25519'), Path('/opt/funtidesk/data/id_ed25519.pub')]
    hashes = {p: hashlib.sha256(p.read_bytes()).digest() for p in protected}
    state = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
    relay = [v for v in state if v['Name'] == '/funtidesk-account-witness-relay-1']
    if any(v['Config'].get('Labels', {}).get('com.docker.compose.project') != 'funtidesk-account' for v in relay):
        raise RuntimeError('Unexpected legacy relay identity')
    removable = {before['Id']} | {v['Id'] for v in relay}
    stable = {v['Name']: v['Id'] for v in state if v['Id'] not in removable}
    relay_networks = {n for v in relay for n in v['NetworkSettings']['Networks']}
    private_file(directory / 'account.env.before', old_env)
    private_file(directory / 'account.env.next', next_env)
    private_file(directory / 'APPLY_STARTED', source.encode())
    run(*compose, 'stop', 'account')
    try:
        backup_and_check(database, directory, pin['source'])
        if (ROOT / 'account.env').read_bytes() != old_env:
            raise RuntimeError('Account environment changed during preparation')
        os.replace(directory / 'account.env.next', ROOT / 'account.env')
        run(*compose, 'up', '-d', '--no-deps', '--pull', 'never', 'account')
        deadline = time.monotonic() + 45
        while True:
            try:
                api_ready(before['NetworkSettings']['Networks']['funtidesk-account-front']['IPAddress'])
                break
            except (OSError, RuntimeError):
                if time.monotonic() >= deadline:
                    raise RuntimeError('Core-only API did not become ready')
                time.sleep(1)
        if database_version(database) != 4:
            raise RuntimeError('Expected the completed v4 migration')
        current = json.loads(run('docker', 'inspect', 'funtidesk-account-account-1'))[0]
        assert current['Image'] == image['Id'] and current['RestartCount'] == 0 and not current['HostConfig']['PortBindings']
        assert all('WITNESS' not in v and 'RECOVERY' not in v for v in current['Config']['Env'])
        assert len(current['NetworkSettings']['Networks']) == 2
        for v in relay:
            run('docker', 'rm', '-f', v['Id'])
        for name in relay_networks:
            network = json.loads(run('docker', 'network', 'inspect', name))[0]
            if network.get('Labels', {}).get('com.docker.compose.project') == 'funtidesk-account' and not network.get('Containers'):
                run('docker', 'network', 'rm', name)
        after = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
        assert {v['Name']: v['Id'] for v in after if v['Name'] in stable} == stable
        assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in hashes.items())
        assert (ROOT / 'account.env').read_bytes() == next_env
        receipt = {'apiSource': pin['source'], 'toolsSource': source, 'apiImage': image['Id'], 'previousApiImage': before['Image'],
                   'artifactRun': pin['run_id'], 'artifactId': pin['artifact_id'], 'databaseVersion': 4,
                   'backup': str(directory / 'account.sqlite3.before'), 'migrationPreviewPreservedAllApplicationTables': True,
                   'otherContainersAndKeysPreserved': True, 'witnessRelayRemoved': True, 'deRequired': False}
        private_file(ROOT / 'integration/api-local-update.json', json.dumps(receipt, indent=2).encode())
        print('DESK_LOCAL_API_READY')
    except Exception:
        # Never replace the current DB with an old copy or run a v3 binary on v4.
        exists = subprocess.run(['docker', 'inspect', before['Id']], capture_output=True, timeout=10)
        if exists.returncode == 0:
            run('docker', 'start', before['Id'])
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        update(args.archive, args.apply)
    except Exception as error:
        print('DESK_LOCAL_API_FAILED: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__))
        raise SystemExit(1)
