#!/usr/bin/env python3
"""Зашифровать ключи кабинета или согласованный hbbs snapshot без plaintext-файлов."""
import argparse
import base64
from contextlib import closing
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import time
import uuid

ACCOUNT = Path('/opt/funtidesk-account')
SERVER = Path('/opt/funtidesk')
MAX_DATABASE = 64 * 1024 * 1024


class BackupError(Exception):
    pass


def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_file(path, private=False, limit=1024 * 1024, allow_group_read=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise BackupError('Invalid backup input file')
        forbidden_permissions = 0o037 if allow_group_read else 0o077
        if private and info.st_mode & forbidden_permissions:
            raise BackupError('Backup secret file permissions are too broad')
        content = source.read(limit + 1)
        if len(content) > limit or signature(os.fstat(source.fileno())) != signature(info):
            raise BackupError('Backup input changed while reading')
    return content, info


def recipient_from_input(path=None):
    content = read_file(path, private=True, limit=256)[0] if path else sys.stdin.buffer.readline(256)
    recipient = content.strip()
    if not re.fullmatch(rb'age1[023456789acdefghjklmnpqrstuvwxyz]{58}', recipient):
        raise BackupError('One X25519 age recipient is required')
    return recipient + b'\n'


def sqlite_snapshot(path):
    if not path.is_file() or path.is_symlink() or not hasattr(sqlite3.Connection, 'serialize'):
        raise BackupError('A real hbbs database and Python SQLite serialization support are required')
    deadline = time.monotonic() + 60

    def progress(status, remaining, total):
        if time.monotonic() >= deadline or total * page_size > MAX_DATABASE:
            raise BackupError('SQLite snapshot limit exceeded')

    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=5)) as source, \
            closing(sqlite3.connect(':memory:')) as destination:
        source.execute('PRAGMA query_only=ON')
        page_size = source.execute('PRAGMA page_size').fetchone()[0]
        if source.execute('PRAGMA page_count').fetchone()[0] * page_size > MAX_DATABASE:
            raise BackupError('SQLite database is larger than the snapshot memory limit')
        source.backup(destination, pages=256, progress=progress, sleep=0.05)
        if destination.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise BackupError('SQLite snapshot integrity check failed')
        content = destination.serialize()
        if len(content) > MAX_DATABASE:
            raise BackupError('SQLite serialized snapshot limit exceeded')
        return content


def collect(component):
    # Fixed allowlists intentionally exclude account DB/recovery and all witness
    # state: only the current independent witness can authorize account restore.
    if component == 'account-secrets':
        root = ACCOUNT
        files = [
            ('secrets/account.key', True), ('secrets/witness.key', True),
            ('secrets/funtidesk202610.private', True), ('account.env', True),
            ('PREPARED', False), ('dns-records.json', False),
        ]
        optional = ['integration/stage.json', 'integration/Caddyfile.before',
                    'integration/Caddyfile.candidate', 'integration/caddy-account.override.yaml',
                    'integration/hbbs-identity.override.yaml']
    else:
        root = SERVER
        files = [('data/id_ed25519', True), ('data/id_ed25519.pub', False), ('server.env', True)]
        optional = ['DEPLOYED_COMMIT']
    entries = {}
    for name, private in files + [(name, False) for name in optional
                                  if (root / name).exists() or (root / name).is_symlink()]:
        # Existing deploy.sh installs server.env as root:root 0640. It is
        # encrypted operational metadata; private key permissions stay strict.
        entries[name] = read_file(root / name, private,
                                  allow_group_read=component == 'server' and name == 'server.env')
    if component == 'account-secrets':
        for name in ['secrets/account.key', 'secrets/witness.key']:
            if not re.fullmatch(rb'[0-9a-fA-F]{64}', entries[name][0].strip()):
                raise BackupError('Invalid account or witness key encoding')
        environment = entries['account.env'][0]
        if not re.search(rb'^FUNTI_ACCOUNT_WITNESS_NAMESPACE=[0-9a-fA-F]{64}\s*$', environment, re.M):
            raise BackupError('Account witness namespace is missing')
        check = subprocess.run(['openssl', 'pkey', '-check', '-noout'],
                               input=entries['secrets/funtidesk202610.private'][0],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        if check.returncode:
            raise BackupError('Invalid DKIM private key')
    else:
        try:
            private = base64.b64decode(entries['data/id_ed25519'][0].strip(), validate=True)
            public = base64.b64decode(entries['data/id_ed25519.pub'][0].strip(), validate=True)
        except ValueError:
            raise BackupError('Invalid server identity encoding') from None
        if len(private) != 64 or len(public) != 32 or private[32:] != public:
            raise BackupError('Server identity pair does not match')
        snapshot = sqlite_snapshot(root / 'data/db_v2.sqlite3')
        entries['data/db_v2.sqlite3'] = (snapshot, None)
    return root, entries


def unchanged(root, entries):
    for name, (content, info) in entries.items():
        if info is not None:
            current, current_info = read_file(root / name)
            if current != content or signature(current_info) != signature(info):
                raise BackupError('Backup source changed during snapshot or encryption')


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def digest(path):
    value = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as incoming:
        before = os.fstat(incoming.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise BackupError('Ciphertext must be a regular file')
        for chunk in iter(lambda: incoming.read(1024 * 1024), b''):
            value.update(chunk)
        after = os.fstat(incoming.fileno())
        current = path.lstat()
        if signature(before) != signature(after) or signature(after) != signature(current):
            raise BackupError('Ciphertext changed during checksum verification')
    return value.hexdigest()


def backup(component, output, recipient):
    if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc':
        raise BackupError('Backup must run as root on Core')
    if not shutil.which('age'):
        raise BackupError('age is not installed')
    if not output.is_absolute() or not output.name.endswith('.tar.gz.age'):
        raise BackupError('An absolute .tar.gz.age artifact path is required')
    sidecar = Path(str(output) + '.sha256')
    if output.exists() or output.is_symlink() or sidecar.exists() or sidecar.is_symlink():
        raise BackupError('Backup artifact already exists; refusing to overwrite')
    directory = output.parent
    info = directory.stat()
    if directory.is_symlink() or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        raise BackupError('Backup directory must already be root-owned mode 0700')
    root, entries = collect(component)
    unchanged(root, entries)
    manifest = {'format': 1, 'component': component, 'createdUtc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                'restoreNote': 'Account state is restored only from the current independent witness; this archive never resets witness.',
                'sqliteMethod': 'SQLite Online Backup to RAM, integrity_check, serialize' if component == 'server' else None,
                'files': {name: {'sha256': hashlib.sha256(content).hexdigest(), 'bytes': len(content)}
                          for name, (content, _) in entries.items()}}
    partial = directory / ('.ciphertext-' + uuid.uuid4().hex + '.partial')
    recipient_fd = os.memfd_create('funti-age-recipient', os.MFD_CLOEXEC)
    os.write(recipient_fd, recipient)
    os.lseek(recipient_fd, 0, os.SEEK_SET)
    try:
        descriptor = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as encrypted:
            client = subprocess.Popen(['age', '-R', '/proc/self/fd/' + str(recipient_fd)],
                                      stdin=subprocess.PIPE, stdout=encrypted, stderr=subprocess.PIPE,
                                      pass_fds=(recipient_fd,))
            try:
                with tarfile.open(mode='w|gz', fileobj=client.stdin) as archive:
                    for name, (content, source_info) in entries.items():
                        member = tarfile.TarInfo(name)
                        member.mode = stat.S_IMODE(source_info.st_mode) if source_info is not None else 0o600
                        member.uid = source_info.st_uid if source_info is not None else 0
                        member.gid = source_info.st_gid if source_info is not None else 0
                        member.size = len(content)
                        archive.addfile(member, io.BytesIO(content))
                    metadata = json.dumps(manifest, indent=2).encode() + b'\n'
                    member = tarfile.TarInfo('BACKUP.json')
                    member.mode, member.size = 0o600, len(metadata)
                    archive.addfile(member, io.BytesIO(metadata))
                client.stdin.close()
                client.stdin = None
                client.communicate(timeout=120)
                if client.returncode:
                    raise BackupError('age encryption failed')
            except BaseException:
                client.kill()
                client.communicate()
                raise
            encrypted.flush()
            os.fsync(encrypted.fileno())
        unchanged(root, entries)
        # Hard-link publication refuses an existing destination atomically.
        os.link(partial, output)
        partial.unlink()
        checksum = digest(output)
        descriptor = os.open(sidecar, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as metadata:
            metadata.write(checksum + '  ' + output.name + '\n')
            metadata.flush()
            os.fsync(metadata.fileno())
        fsync_directory(directory)
        return {'component': component, 'sha256': checksum, 'bytes': output.stat().st_size}
    finally:
        os.close(recipient_fd)
        partial.unlink(missing_ok=True)


def verify_copy(artifact, expected):
    if not re.fullmatch(r'[0-9a-f]{64}', expected) or artifact.is_symlink() or not artifact.is_file():
        raise BackupError('A ciphertext file and trusted SHA256 are required')
    if digest(artifact) != expected:
        raise BackupError('Independent ciphertext copy checksum mismatch')
    return {'verified': True, 'sha256': expected, 'bytes': artifact.stat().st_size}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('backup')
    create.add_argument('--component', choices=['account-secrets', 'server'], required=True)
    create.add_argument('--output', type=Path, required=True)
    create.add_argument('--recipient-file', type=Path)
    verify = commands.add_parser('verify-copy')
    verify.add_argument('--artifact', type=Path, required=True)
    verify.add_argument('--expected-sha256', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'backup':
            # Bound encryption, including a blocked tar-to-age pipe write.
            def expired(signum, frame):
                raise BackupError('Backup deadline exceeded')
            signal.signal(signal.SIGALRM, expired)
            signal.alarm(180)
            try:
                result = backup(args.component, args.output, recipient_from_input(args.recipient_file))
            finally:
                signal.alarm(0)
        else:
            result = verify_copy(args.artifact, args.expected_sha256)
        print(json.dumps(result))
    except Exception as error:
        reason = str(error) if isinstance(error, BackupError) else type(error).__name__
        print('BACKUP_FAILED: ' + reason, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
