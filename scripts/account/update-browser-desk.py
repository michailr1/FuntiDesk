#!/usr/bin/env python3
"""Stage a browser-only candidate without changing the active account API or pages."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess

REPO = Path(__file__).resolve().parents[2]
ROOT = Path('/opt/funtidesk-account')
CURRENT = Path('/opt/funtidesk-web/current')
CADDY = Path('/opt/remnawave/caddy/Caddyfile')
BASE = Path('/opt/remnawave/caddy/docker-compose.yml')


def load(name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts/account' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError('Browser update operation failed: ' + args[0])
    return result.stdout


def browser_config(original, fragment):
    stage = load('stage-desk')
    marker = 'FUNTIDESK_DESK_UPDATE_MARKER'
    split = stage.replace_desk(original, marker)
    prefix, suffix = split.split(marker)
    block = original[len(prefix):len(original) - len(suffix) if suffix else None]
    if '/ws/rendezvous' in block or '/connect' in block:
        raise RuntimeError('Browser routes already exist; inspect before updating')
    matches = list(re.finditer(r'(?m)^\s*handle\s*\{', block))
    if len(matches) != 1:
        raise RuntimeError('Expected one desk fallback handler')
    offset = matches[0].start()
    candidate = block[:offset] + '\n' + fragment.strip() + '\n' + block[offset:]
    return stage.replace_desk(original, candidate)


def network_only(base, proposed):
    if set(base['services']) != {'caddy'} or set(proposed['services']) != {'caddy'}:
        raise RuntimeError('Unexpected Caddy project services')
    old, new = base['services']['caddy'], proposed['services']['caddy']
    if {k: v for k, v in old.items() if k != 'networks'} != {k: v for k, v in new.items() if k != 'networks'}:
        raise RuntimeError('Browser overlay changes Caddy fields other than networks')
    if set(new['networks']) != set(old['networks']) | {'funtidesk-server'}:
        raise RuntimeError('Unexpected browser network addition')
    for name, settings in old['networks'].items():
        if (new['networks'][name] or {}) != (settings or {}) or proposed['networks'][name] != base['networks'][name]:
            raise RuntimeError('Browser overlay changes an existing network')
    if base.get('volumes') != proposed.get('volumes'):
        raise RuntimeError('Browser overlay changes Caddy volumes')
    if proposed['networks']['funtidesk-server'].get('name') != 'funtidesk-server' or not proposed['networks']['funtidesk-server'].get('external'):
        raise RuntimeError('Browser backend must use the existing external server network')


def stage_files(old, source, release):
    previous = json.loads((old / 'manifest.json').read_text())['artifacts']
    latest = json.loads((source / 'manifest.json').read_text())['artifacts']
    browser = [item for item in latest if item['file'].startswith('connect/')]
    if not browser or any(item['file'].startswith('connect/') for item in previous):
        raise RuntimeError('Expected a new browser-only release')
    selected = [(old, item) for item in previous] + [(source, item) for item in browser]
    checked = []
    for root, item in selected:
        path = Path(item['file'])
        if path.is_absolute() or '..' in path.parts or (root / path).is_symlink():
            raise RuntimeError('Unsafe web manifest path')
        data = (root / path).read_bytes()
        if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise RuntimeError('Web manifest mismatch')
        checked.append((path, data))
    release.mkdir(mode=0o755)
    for path, data in checked:
        destination = release / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(0o444)
    (release / 'manifest.json').write_text(json.dumps({'artifacts': previous + browser}, indent=2) + '\n')
    return len(checked)


def update():
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc' or not (ROOT / 'ACTIVATED').is_file():
        raise RuntimeError('Browser update requires the active Core cabinet')
    if run('git', '-C', str(REPO), 'status', '--porcelain').strip():
        raise RuntimeError('Source must be clean')
    source = run('git', '-C', str(REPO), 'rev-parse', 'HEAD').decode().strip()
    folder = ROOT / 'updates' / ('browser-' + source[:12])
    overlay = ROOT / 'integration/caddy-web-client.override.yaml'
    if overlay.exists():
        raise RuntimeError('Unexpected previous browser overlay')
    if folder.exists():
        raise RuntimeError('Browser update directory already exists')
    old_link = os.readlink(CURRENT)
    old_root = CURRENT.resolve(strict=True)
    old_config = CADDY.read_bytes()
    candidate = browser_config(old_config.decode(), (REPO / 'infra/funtidesk-account/Caddyfile.web-client.fragment').read_text()).encode()
    ids = run('docker', 'ps', '-q', '--filter', 'label=com.docker.compose.project=caddy', '--filter', 'label=com.docker.compose.service=caddy').decode().split()
    if len(ids) != 1:
        raise RuntimeError('Expected one active Caddy')
    live = json.loads(run('docker', 'inspect', ids[0]))[0]
    compose = ['docker', 'compose', '-p', 'caddy', '--env-file', str(ROOT / 'account.env'), '-f', str(BASE), '-f', str(ROOT / 'integration/caddy-account.override.yaml')]
    proposed = compose + ['-f', str(REPO / 'infra/funtidesk-account/caddy-web-client.override.yaml')]
    base_model = json.loads(run(*compose, 'config', '--format', 'json'))
    model = json.loads(run(*proposed, 'config', '--format', 'json'))
    network_only(base_model, model)
    if run(*compose, 'config', '--hash', 'caddy').decode().split() != ['caddy', live['Config']['Labels']['com.docker.compose.config-hash']]:
        raise RuntimeError('Base Compose differs from the live Caddy configuration')
    configured = {v['target']: v for v in base_model['services']['caddy']['volumes']}
    mounted = {v['Destination']: v for v in live['Mounts']}
    if set(configured) != set(mounted) or not {'/data', '/etc/caddy/Caddyfile', '/usr/share/caddy'} <= set(mounted):
        raise RuntimeError('Unexpected live Caddy mounts')
    for target, desired in configured.items():
        actual = mounted[target]
        if actual['Type'] != desired['type'] or actual['RW'] != (not desired.get('read_only', False)):
            raise RuntimeError('Caddy mount type or permissions differ from Compose')
        if desired['type'] == 'bind':
            if Path(actual['Source']).resolve() != Path(desired['source']).resolve():
                raise RuntimeError('Caddy bind source differs from Compose')
        elif desired['type'] == 'volume':
            if actual.get('Name') != base_model.get('volumes', {}).get(desired['source'], {}).get('name'):
                raise RuntimeError('Caddy SSL or other volume identity differs from Compose')
        else:
            raise RuntimeError('Unsupported Caddy mount type')
    if json.loads(run('docker', 'image', 'inspect', model['services']['caddy']['image']))[0]['Id'] != live['Image']:
        raise RuntimeError('Browser update would change the Caddy image')
    if set(live['NetworkSettings']['Networks']) != {base_model['networks'][name]['name'] for name in base_model['services']['caddy']['networks']}:
        raise RuntimeError('Base Compose omits a live Caddy network')
    backend = json.loads(run('docker', 'network', 'inspect', 'funtidesk-server'))
    if len(backend) != 1:
        raise RuntimeError('Ambiguous server network')
    for service in ['funtidesk-hbbs', 'funtidesk-hbbr']:
        info = json.loads(run('docker', 'inspect', service))[0]
        if info['NetworkSettings']['Networks']['funtidesk-server']['NetworkID'] != backend[0]['Id']:
            raise RuntimeError('Unexpected browser backend network')
    run('docker', 'exec', '-i', ids[0], 'caddy', 'validate', '--config', '/dev/stdin', '--adapter', 'caddyfile', data=candidate)
    api = json.loads(run('docker', 'inspect', 'funtidesk-account-account-1'))[0]
    api_data = next(Path(m['Source']) for m in api['Mounts'] if m['Destination'] == '/data')
    import sqlite3
    db = sqlite3.connect('file:' + str(api_data / 'account.sqlite3') + '?mode=ro', uri=True)
    version = db.execute('PRAGMA user_version').fetchone()[0]
    db.close()
    protected = [ROOT / 'account.env', ROOT / 'secrets/account.key', ROOT / 'secrets/witness.key', ROOT / 'secrets/funtidesk202610.private', Path('/opt/funtidesk/data/id_ed25519'), Path('/opt/funtidesk/data/id_ed25519.pub')]
    hashes = {p: hashlib.sha256(p.read_bytes()).digest() for p in protected}
    containers = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
    stable = {v['Name']: v['Id'] for v in containers if v['Id'] != live['Id']}
    folder.mkdir(parents=True, mode=0o700)
    for name, data in [('Caddyfile.before', old_config), ('Caddyfile.candidate', candidate)]:
        path = folder / name
        path.write_bytes(data)
        path.chmod(0o600)
    release = Path('/opt/funtidesk-web/releases') / (source + '-browser')
    count = stage_files(old_root, REPO / 'web', release)
    (release / 'SOURCE.json').write_text(json.dumps({'baseWeb': str(old_root), 'browserSource': source}) + '\n')
    activation = load('activate-desk')
    changed = False
    overlay_created = False
    try:
        if CADDY.read_bytes() != old_config or os.readlink(CURRENT) != old_link:
            raise RuntimeError('Live configuration changed during staging')
        changed = True
        activation.switch_link(str(release))
        activation.write_config(candidate)
        run(*proposed, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
        activation.wait_ready([('https://desk.funti.cc/', 200, b'FuntiDesk'), ('https://desk.funti.cc/account/', 200, b'FuntiDesk'), ('https://desk.funti.cc/connect/', 200, b'connection-form'), ('https://desk.funti.cc/api/account/v1/session', 401, b'authentication_required')])
        after = json.loads(run('docker', 'inspect', *run('docker', 'ps', '-aq').decode().split()))
        assert {v['Name']: v['Id'] for v in after if v['Name'] in stable} == stable
        assert all(hashlib.sha256(p.read_bytes()).digest() == digest for p, digest in hashes.items())
        check = sqlite3.connect('file:' + str(api_data / 'account.sqlite3') + '?mode=ro', uri=True)
        assert check.execute('PRAGMA user_version').fetchone()[0] == version
        check.close()
        descriptor = os.open(overlay, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        overlay_created = True
        with os.fdopen(descriptor, 'wb') as output:
            output.write((REPO / 'infra/funtidesk-account/caddy-web-client.override.yaml').read_bytes())
        receipt = {'source': source, 'browserWebroot': str(release), 'previousWebroot': old_link, 'webFiles': count, 'apiAndOtherContainersPreserved': True, 'keysAndEnvironmentPreserved': True, 'databaseVersion': version, 'fullAccountPagesPreserved': True, 'liveWindowsAcceptance': False}
        (folder / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        (folder / 'receipt.json').chmod(0o600)
        print('DESK_BROWSER_CANDIDATE_READY')
    except Exception:
        if overlay_created:
            overlay.unlink()
        if changed:
            activation.switch_link(old_link)
            activation.write_config(old_config)
            run(*compose, 'up', '-d', '--no-deps', '--pull', 'never', '--force-recreate', 'caddy')
            activation.wait_ready([('https://desk.funti.cc/', 200, b'FuntiDesk'), ('https://desk.funti.cc/account/', 200, b'FuntiDesk')])
        raise


if __name__ == '__main__':
    try:
        update()
    except Exception as error:
        print('DESK_BROWSER_UPDATE_FAILED: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__))
        raise SystemExit(1)
