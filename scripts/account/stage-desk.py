#!/usr/bin/env python3
"""Подготовить полный конфиг и публичный webroot кабинета на Core."""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[2]
ROOT = Path('/opt/funtidesk-account')
CADDY = Path('/opt/remnawave/caddy/Caddyfile')


def run(*args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError('Stage operation failed: ' + args[0])
    return result.stdout


def replace_desk(original, block):
    starts = list(re.finditer(r'(?m)^desk\.funti\.cc\s*\{', original))
    if len(starts) != 1:
        raise RuntimeError('Expected exactly one desk.funti.cc block')
    start = starts[0].start()
    depth = 0
    for index in range(original.index('{', start), len(original)):
        if original[index] == '{':
            depth += 1
        elif original[index] == '}':
            depth -= 1
            if depth == 0:
                return original[:start] + block.strip() + original[index + 1:]
    raise RuntimeError('Unterminated desk.funti.cc block')


def stage():
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc':
        raise RuntimeError('Stage must run as root on Core')
    if run('git', '-C', str(REPO), 'status', '--porcelain').strip():
        raise RuntimeError('Source checkout must be clean')
    if not (ROOT / 'PREPARED').is_file():
        raise RuntimeError('Verified account preparation is required')
    directory = ROOT / 'integration'
    if directory.exists() or directory.is_symlink():
        raise RuntimeError('Integration stage already exists; inspect before replacing')
    original = CADDY.read_text()
    block = (REPO / 'infra/funtidesk-account/Caddyfile.desk.proposed').read_text()
    block = block[block.index('desk.funti.cc {'):]
    candidate = replace_desk(original, block)
    caddy = run('docker', 'ps', '--filter', 'label=com.docker.compose.project=caddy',
                '--filter', 'label=com.docker.compose.service=caddy', '--format', '{{.ID}}').decode().split()
    if len(caddy) != 1:
        raise RuntimeError('Expected one live Core Caddy')
    info = json.loads(run('docker', 'inspect', caddy[0]))[0]
    image = info['Image']
    mounts = {item['Destination']: item for item in info['Mounts']}
    if mounts.get('/etc/caddy/Caddyfile', {}).get('Source') != str(CADDY):
        raise RuntimeError('Unexpected Core Caddy configuration mount')
    run('docker', 'exec', '-i', caddy[0], 'caddy', 'validate', '--config', '/dev/stdin',
        '--adapter', 'caddyfile', data=candidate.encode())
    source = json.loads((REPO / 'infra/funtidesk-account/account-release.json').read_text())['source']
    release = Path('/opt/funtidesk-web/releases') / (source + '-account')
    if release.exists() or release.is_symlink():
        raise RuntimeError('Account web release already exists; inspect before replacing')
    with tempfile.TemporaryDirectory(prefix='funtidesk-web-stage-') as temporary:
        archive = Path(temporary) / 'web.tar'
        run('python3', str(REPO / 'scripts/web/package.py'), '--output', str(archive))
        manifest = json.loads((REPO / 'web/manifest.json').read_text())
        with tarfile.open(archive) as incoming:
            for member in incoming.getmembers():
                path = Path(member.name)
                if not member.isfile() or path.is_absolute() or '..' in path.parts:
                    raise RuntimeError('Unsafe public web package')
            release.mkdir(mode=0o755)
            incoming.extractall(release, filter='data')
        for item in manifest['artifacts']:
            if hashlib.sha256((release / item['file']).read_bytes()).hexdigest() != item['sha256']:
                raise RuntimeError('Public web manifest mismatch')
        (release / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        (release / 'SOURCE_COMMIT').write_text(source + '\n')
    directory.mkdir(mode=0o700)
    for name, contents in [('Caddyfile.before', original), ('Caddyfile.candidate', candidate)]:
        path = directory / name
        path.write_text(contents)
        path.chmod(0o600)
    for name in ['caddy-account.override.yaml', 'hbbs-identity.override.yaml']:
        (directory / name).write_bytes((REPO / 'infra/funtidesk-account' / name).read_bytes())
    record = {'sourceCommit': run('git', '-C', str(REPO), 'rev-parse', 'HEAD').decode().strip(),
              'binarySource': source, 'webRelease': str(release),
              'previousWebRoot': os.readlink('/opt/funtidesk-web/current'),
              'caddyContainerBefore': caddy[0], 'caddyImage': image,
              'caddyBeforeSha256': hashlib.sha256(original.encode()).hexdigest(),
              'caddyCandidateSha256': hashlib.sha256(candidate.encode()).hexdigest(),
              'webFiles': len(manifest['artifacts']), 'candidateValidated': True}
    (directory / 'stage.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))


if __name__ == '__main__':
    try:
        stage()
    except Exception as error:
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print('DESK_STAGE_FAILED: ' + reason)
        raise SystemExit(1)
