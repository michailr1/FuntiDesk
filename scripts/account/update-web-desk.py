#!/usr/bin/env python3
"""Update the active v3 cabinet's static files, preserving API, Caddy config and images."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket

REPO = Path(__file__).resolve().parents[2]
ROOT = Path('/opt/funtidesk-account')
CURRENT = Path('/opt/funtidesk-web/current')
CADDY = Path('/opt/remnawave/caddy/Caddyfile')


def load(name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts/account' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def update():
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc' or not (ROOT / 'ACTIVATED').is_file():
        raise RuntimeError('Static update requires the active Core cabinet')
    library = load('update-library-desk')
    run = library.run
    if run('git', '-C', str(REPO), 'status', '--porcelain').strip():
        raise RuntimeError('Source must be clean')
    source = run('git', '-C', str(REPO), 'rev-parse', 'HEAD').decode().strip()
    before = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
    candidates = [v for v in before if v['Config'].get('Labels', {}).get('com.docker.compose.project') == 'caddy'
                  and v['Config']['Labels'].get('com.docker.compose.service') == 'caddy' and v['State']['Running']]
    if len(candidates) != 1:
        raise RuntimeError('Expected one running public Caddy')
    caddy = candidates[0]
    api = next(v for v in before if v['Name'] == '/funtidesk-account-account-1')
    data = next(Path(m['Source']) for m in api['Mounts'] if m['Destination'] == '/data')
    if not api['State']['Running'] or library.database_version(data / 'account.sqlite3') != 3:
        raise RuntimeError('Expected the active compatible v3 API')
    library.api_ready(api['NetworkSettings']['Networks']['funtidesk-account-front']['IPAddress'])
    compose = ['docker', 'compose', '-p', 'caddy', '--env-file', str(ROOT / 'account.env'),
               '-f', '/opt/remnawave/caddy/docker-compose.yml',
               '-f', str(ROOT / 'integration/caddy-account.override.yaml'),
               '-f', str(ROOT / 'integration/caddy-web-client.override.yaml')]
    if run(*compose, 'config', '--hash', 'caddy').decode().split() != ['caddy', caddy['Config']['Labels']['com.docker.compose.config-hash']]:
        raise RuntimeError('Compose differs from live Caddy')
    protected = [ROOT / 'account.env', CADDY]
    hashes = {p: hashlib.sha256(p.read_bytes()).digest() for p in protected}
    stable = {v['Name']: v['Id'] for v in before if v['Id'] != caddy['Id']}
    old_link = os.readlink(CURRENT)
    release = CURRENT.parent / 'releases' / (source + '-web')
    previous_umask = os.umask(0o022)
    try:
        library.stage_full_web(release)
        (release / 'SOURCE_COMMIT').write_text(source + '\n')
    finally:
        os.umask(previous_umask)
    directory = ROOT / 'updates' / ('web-' + source[:12])
    directory.mkdir(mode=0o700)
    library.private_file(directory / 'before.json', json.dumps({'webroot': old_link, 'source': source}).encode())
    activation = load('activate-desk')
    if os.readlink(CURRENT) != old_link or any(hashlib.sha256(p.read_bytes()).digest() != digest for p, digest in hashes.items()):
        raise RuntimeError('Live state changed during static preparation')
    activation.switch_link(str(release))
    try:
        run(*compose, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
        activation.wait_ready([('https://desk.funti.cc/account/', 200, b'favorites-title'),
                               ('https://desk.funti.cc/account/account.js', 200, b'refreshSignedInLists'),
                               ('https://desk.funti.cc/connect/', 200, b'connection-form'),
                               ('https://desk.funti.cc/api/account/v1/library', 401, b'authentication_required')])
        after = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
        new = next(v for v in after if v['Name'] == caddy['Name'])
        assert {v['Name']: v['Id'] for v in after if v['Name'] in stable} == stable
        assert new['Image'] == caddy['Image']
        assert new['HostConfig']['PortBindings'] == caddy['HostConfig']['PortBindings']
        assert {m['Destination']: (m.get('Name'), m['RW']) for m in new['Mounts']} == {m['Destination']: (m.get('Name'), m['RW']) for m in caddy['Mounts']}
        assert set(new['NetworkSettings']['Networks']) == set(caddy['NetworkSettings']['Networks'])
        assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in hashes.items())
        library.private_file(directory / 'receipt.json', json.dumps({'webSource': source, 'webroot': str(release),
                             'previousWebroot': old_link, 'apiAndOtherContainersPreserved': True,
                             'caddyConfigImageVolumesAndNetworksPreserved': True}).encode())
        print('DESK_STATIC_WEB_READY')
    except Exception:
        activation.switch_link(old_link)
        run(*compose, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
        activation.wait_ready([('https://desk.funti.cc/account/', 200, b'favorites-title')])
        raise


if __name__ == '__main__':
    try:
        update()
    except Exception as error:
        print('DESK_STATIC_WEB_FAILED: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__))
        raise SystemExit(1)
