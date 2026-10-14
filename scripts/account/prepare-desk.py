#!/usr/bin/env python3
"""Закреплённая поставка и отдельные секреты кабинета на Core."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

REPO = Path(__file__).resolve().parents[2]
ROOT = Path('/opt/funtidesk-account')
RELEASE = json.loads((REPO / 'infra/funtidesk-account/account-release.json').read_text())
MARKER = 'FuntiDesk account preparation v1'


def run(*args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError('Operation failed: ' + args[0])
    return result.stdout


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_archive(archive, directory):
    if digest(archive) != RELEASE['artifact_zip_sha256']:
        raise RuntimeError('Artifact ZIP checksum mismatch')
    with zipfile.ZipFile(archive) as incoming:
        for item in incoming.infolist():
            if Path(item.filename).name != item.filename or item.file_size > 128 * 1024 * 1024:
                raise RuntimeError('Unsafe artifact member')
            incoming.extract(item, directory)
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        expected, name = line.split(maxsplit=1)
        name = name.lstrip('*')
        if Path(name).name != name or digest(directory / name) != expected:
            raise RuntimeError('Artifact manifest mismatch')
    if (directory / 'SOURCE_REVISION').read_text().strip() != RELEASE['source']:
        raise RuntimeError('Artifact source revision mismatch')
    if digest(directory / 'account-images.tar.gz') != RELEASE['docker_archive_sha256']:
        raise RuntimeError('Docker archive checksum mismatch')
    images = json.loads((directory / 'IMAGES.json').read_text())
    actual = {i['RepoTags'][0].split(':')[0]: i['Id'] for i in images}
    if actual != RELEASE['images'] or any(
            i['Config']['Labels'].get('org.opencontainers.image.revision') != RELEASE['source'] for i in images):
        raise RuntimeError('Image provenance mismatch')
    return images


def source_qualified_archive(directory):
    destination = directory / 'qualified-images.tar'
    with tarfile.open(directory / 'account-images.tar.gz', 'r:gz') as incoming:
        manifest = json.load(incoming.extractfile('manifest.json'))
        for image in manifest:
            image['RepoTags'] = [tag.split(':')[0] + ':' + RELEASE['source'][:12] for tag in image['RepoTags']]
        content = json.dumps(manifest).encode()
        import io
        with tarfile.open(destination, 'w') as outgoing:
            for member in incoming:
                if member.name in ['manifest.json', 'repositories']:
                    continue
                outgoing.addfile(member, incoming.extractfile(member) if member.isfile() else None)
            member = tarfile.TarInfo('manifest.json')
            member.size = len(content)
            outgoing.addfile(member, io.BytesIO(content))
    return destination


def create_secret(path, uid, value):
    if path.exists() or path.is_symlink():
        raise RuntimeError('Refusing to replace existing secret')
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o400)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(value + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.chown(path, uid, uid)


def prepare(archive):
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc':
        raise RuntimeError('Preparation must run as root on Core')
    if run('git', '-C', str(REPO), 'status', '--porcelain').strip():
        raise RuntimeError('Source checkout must be clean')
    if ROOT.exists() or ROOT.is_symlink():
        raise RuntimeError('Account path already exists; inspect before preparation')
    for name, expected in RELEASE['images'].items():
        existing = subprocess.run(['docker','image','inspect','--format','{{.Id}}',
                                   name+':'+RELEASE['source'][:12]],capture_output=True,text=True)
        if existing.returncode == 0 and existing.stdout.strip() != expected:
            raise RuntimeError('Source-qualified image tag already refers to another image')
    with tempfile.TemporaryDirectory(prefix='funtidesk-account-delivery-') as temporary:
        directory = Path(temporary)
        verify_archive(archive, directory)
        qualified = source_qualified_archive(directory)
        run('docker', '--host=unix:///var/run/docker.sock', 'load', '--input', str(qualified))
    for name, expected in RELEASE['images'].items():
        tag = name + ':' + RELEASE['source'][:12]
        actual = run('docker', 'image', 'inspect', '--format', '{{.Id}}', tag).decode().strip()
        if actual != expected:
            raise RuntimeError('Loaded image ID mismatch')
    ROOT.mkdir(mode=0o750)
    (ROOT / 'PREPARED').write_text(MARKER + '\n' + run('git','-C',str(REPO),'rev-parse','HEAD').decode())
    for name, mode, uid, gid in [('data',0o700,10001,10001),('secrets',0o700,0,0),
                                  ('identity',0o750,0,10001),('mail-queue',0o700,0,0),('backups',0o700,0,0)]:
        path=ROOT/name
        path.mkdir(mode=mode)
        os.chown(path,uid,gid)
    create_secret(ROOT/'secrets/account.key',10001,secrets.token_hex(32))
    create_secret(ROOT/'secrets/witness.key',10001,secrets.token_hex(32))
    private=ROOT/'secrets/funtidesk202610.private'
    run('openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(private))
    private.chmod(0o600)
    public=run('openssl','pkey','-in',str(private),'-pubout','-outform','DER')
    import base64
    namespace=secrets.token_hex(32)
    environment=(REPO/'infra/funtidesk-account/.env.example').read_text()
    for name,image in [('FUNTI_ACCOUNT_IMAGE','funtidesk-account'),('FUNTI_ACCOUNT_MAIL_IMAGE','funtidesk-account-mail')]:
        lines=environment.splitlines()
        environment='\n'.join(name+'='+RELEASE['images'][image] if line.startswith(name+'=') else line for line in lines)+'\n'
    environment=environment.replace('7777777777777777777777777777777777777777777777777777777777777777',namespace)
    (ROOT/'account.env').write_text(environment)
    (ROOT/'account.env').chmod(0o600)
    records={'SPF':{'name':'funti.cc','value':'v=spf1 mx a:funti.cc ip4:172.245.108.154 ip4:173.249.195.36 include:sendinblue.com ~all'},
             'DKIM':{'name':'funtidesk202610._domainkey.funti.cc','value':'v=DKIM1; k=rsa; p='+base64.b64encode(public).decode()}}
    (ROOT/'dns-records.json').write_text(json.dumps(records,indent=2)+'\n')
    print(json.dumps({'prepared':True,'source':RELEASE['source'],'databaseInitialized':False,'dnsRecords':records}))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-only',type=Path)
    parser.add_argument('--artifact-url-stdin',action='store_true')
    args=parser.parse_args()
    try:
        if args.verify_only:
            with tempfile.TemporaryDirectory() as temp:
                verify_archive(args.verify_only,Path(temp))
            print('ACCOUNT_ARTIFACT_VERIFIED')
        elif args.artifact_url_stdin:
            url=sys.stdin.readline().strip()
            if not url.startswith('https://'):raise RuntimeError('HTTPS artifact reference required')
            with tempfile.TemporaryDirectory(prefix='funtidesk-account-download-') as temp:
                archive=Path(temp)/'artifact.zip'
                with urllib.request.urlopen(url,timeout=60) as source, archive.open('wb') as output:
                    shutil.copyfileobj(source,output,1024*1024)
                prepare(archive)
        else:
            parser.error('Choose --verify-only or --artifact-url-stdin')
    except Exception as error:
        print('ACCOUNT_PREPARATION_FAILED: '+(str(error) if isinstance(error,RuntimeError) else type(error).__name__),file=sys.stderr)
        return 1
    return 0


if __name__=='__main__':
    raise SystemExit(main())
