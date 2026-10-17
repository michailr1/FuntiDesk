#!/usr/bin/env python3
"""Изолированный round-trip age, WAL snapshot и fail-closed проверки backup helper."""
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

directory = Path(__file__).parent
spec = importlib.util.spec_from_file_location('backup_desk', directory / 'backup-desk.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class BackupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='funti-backup-fixture-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.identity = cls.root / 'ephemeral.agekey'
        cls.age = shutil.which('age')
        age_keygen = shutil.which('age-keygen')
        if not cls.age or not age_keygen:
            raise RuntimeError('age and age-keygen must be installed for backup tests')
        subprocess.run([age_keygen, '-o', str(cls.identity)], check=True, capture_output=True)
        cls.recipient = subprocess.run([age_keygen, '-y', str(cls.identity)],
                                       check=True, capture_output=True).stdout
        cls.dkim = subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048'],
                                  check=True, capture_output=True).stdout

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='case-', dir=self.root)
        self.addCleanup(temporary.cleanup)
        self.case = Path(temporary.name)
        self.account, self.server, self.outputs = [self.case / name for name in ['account', 'server', 'backups']]
        for path in [self.account / 'secrets', self.server / 'data', self.outputs]:
            path.mkdir(mode=0o700, parents=True)
        self.write(self.account / 'secrets/account.key', b'a' * 64 + b'\n')
        self.write(self.account / 'secrets/funtidesk202610.private', self.dkim)
        self.write(self.account / 'account.env', b'FUNTI_ACCOUNT_DATABASE=/data/account.sqlite3\n')
        self.write(self.account / 'PREPARED', b'fixture-only\n')
        self.write(self.account / 'dns-records.json', b'{}\n')
        public = os.urandom(32)
        self.write(self.server / 'data/id_ed25519', base64.b64encode(os.urandom(32) + public))
        self.write(self.server / 'data/id_ed25519.pub', base64.b64encode(public))
        self.write(self.server / 'server.env', b'FUNTIDESK_FQDN=fixture.invalid\n')
        (self.server / 'server.env').chmod(0o640)
        self.writer = sqlite3.connect(self.server / 'data/db_v2.sqlite3')
        self.addCleanup(self.writer.close)
        self.writer.execute('PRAGMA journal_mode=WAL')
        self.writer.execute('CREATE TABLE fixture(id INTEGER PRIMARY KEY, value TEXT)')
        self.writer.execute("INSERT INTO fixture(value) VALUES ('row in WAL')")
        self.writer.commit()
        self.enterContext(patch.object(backup, 'ACCOUNT', self.account))
        self.enterContext(patch.object(backup, 'SERVER', self.server))
        self.enterContext(patch.object(backup.os, 'geteuid', return_value=0))
        self.enterContext(patch.object(backup.socket, 'gethostname', return_value='core.funti.cc'))
        original_stat = Path.stat

        def directory_stat(path, *args, **kwargs):
            info = original_stat(path, *args, **kwargs)
            # Test-only owner view for our 0700 fixture; no chown or root bypass
            # option is added to the production CLI.
            return SimpleNamespace(st_uid=0, st_mode=info.st_mode) if path == self.outputs else info

        self.enterContext(patch.object(Path, 'stat', directory_stat))

    @staticmethod
    def write(path, content):
        path.write_bytes(content)
        path.chmod(0o600)

    def decrypt(self, artifact):
        result = subprocess.run([self.age, '-d', '-i', str(self.identity), str(artifact)],
                                check=True, capture_output=True)
        with tarfile.open(fileobj=io.BytesIO(result.stdout), mode='r:gz') as archive:
            return {member.name: archive.extractfile(member).read() for member in archive.getmembers()}

    def test_account_secrets_real_age_round_trip_and_no_plaintext_artifact(self):
        artifact = self.outputs / 'account.tar.gz.age'
        result = backup.backup('account-secrets', artifact, self.recipient)
        members = self.decrypt(artifact)
        self.assertEqual(members['secrets/account.key'], b'a' * 64 + b'\n')
        self.assertNotIn('secrets/witness.key', members)
        self.assertEqual(members['secrets/funtidesk202610.private'], self.dkim)
        self.assertEqual(set(self.outputs.iterdir()), {artifact, Path(str(artifact) + '.sha256')})
        self.assertNotIn(self.dkim, artifact.read_bytes())
        self.assertEqual(result['sha256'], backup.digest(artifact))
        self.assertNotIn('namespace', json.dumps(result))
        self.assertFalse(any(name.startswith('data/') for name in members))

    def test_server_real_age_round_trip_contains_committed_wal_and_same_identity(self):
        self.assertGreater((self.server / 'data/db_v2.sqlite3-wal').stat().st_size, 0)
        artifact = self.outputs / 'server.tar.gz.age'
        backup.backup('server', artifact, self.recipient)
        members = self.decrypt(artifact)
        # Restore synthetic fixture into the test's private temporary directory;
        # a WAL-mode SQLite file is reopened as a real file, not deserialize().
        restored = self.case / 'fixture-restored.sqlite3'
        self.write(restored, members['data/db_v2.sqlite3'])
        connection = sqlite3.connect(restored)
        self.addCleanup(connection.close)
        self.assertEqual(connection.execute('SELECT value FROM fixture').fetchall(), [('row in WAL',)])
        self.assertEqual(connection.execute('PRAGMA integrity_check').fetchall(), [('ok',)])
        self.assertEqual(members['data/id_ed25519'], (self.server / 'data/id_ed25519').read_bytes())
        self.assertEqual((self.server / 'server.env').stat().st_mode & 0o777, 0o640)
        self.assertEqual(set(self.outputs.iterdir()), {artifact, Path(str(artifact) + '.sha256')})

    def test_server_metadata_group_write_and_world_read_are_rejected(self):
        for mode in [0o660, 0o644]:
            with self.subTest(mode=oct(mode)):
                (self.server / 'server.env').chmod(mode)
                with self.assertRaisesRegex(backup.BackupError, 'permissions are too broad'):
                    backup.backup('server', self.outputs / 'invalid.tar.gz.age', self.recipient)
                self.assertEqual(list(self.outputs.iterdir()), [])

    def test_server_private_key_group_read_is_still_rejected(self):
        (self.server / 'data/id_ed25519').chmod(0o640)
        with self.assertRaisesRegex(backup.BackupError, 'permissions are too broad'):
            backup.backup('server', self.outputs / 'invalid.tar.gz.age', self.recipient)
        self.assertEqual(list(self.outputs.iterdir()), [])

    def test_existing_artifact_is_never_overwritten(self):
        artifact = self.outputs / 'existing.tar.gz.age'
        artifact.write_bytes(b'preserve existing ciphertext')
        with self.assertRaisesRegex(backup.BackupError, 'already exists'):
            backup.backup('server', artifact, self.recipient)
        self.assertEqual(artifact.read_bytes(), b'preserve existing ciphertext')

    def test_mismatched_identity_fails_before_ciphertext_creation(self):
        self.write(self.server / 'data/id_ed25519.pub', base64.b64encode(os.urandom(32)))
        with self.assertRaisesRegex(backup.BackupError, 'does not match'):
            backup.backup('server', self.outputs / 'invalid.tar.gz.age', self.recipient)
        self.assertEqual(list(self.outputs.iterdir()), [])

    def test_independent_copy_digest_and_tampering_rejection(self):
        artifact = self.outputs / 'server.tar.gz.age'
        result = backup.backup('server', artifact, self.recipient)
        other_copy = self.case / 'independent-copy.age'
        shutil.copyfile(artifact, other_copy)
        self.assertTrue(backup.verify_copy(other_copy, result['sha256'])['verified'])
        with other_copy.open('ab') as target:
            target.write(b'tampered')
        with self.assertRaisesRegex(backup.BackupError, 'checksum mismatch'):
            backup.verify_copy(other_copy, result['sha256'])

    def test_recipient_file_requires_private_permissions(self):
        recipient = self.case / 'recipient'
        self.write(recipient, self.recipient)
        self.assertEqual(backup.recipient_from_input(recipient), self.recipient)
        recipient.chmod(0o644)
        with self.assertRaisesRegex(backup.BackupError, 'permissions'):
            backup.recipient_from_input(recipient)

    def test_replaced_ciphertext_during_digest_is_not_verified(self):
        artifact = self.case / 'changing-copy.age'
        artifact.write_bytes(b'original ciphertext')
        real_sha256 = backup.hashlib.sha256
        expected = real_sha256(artifact.read_bytes()).hexdigest()

        class ReplacingHash:
            def __init__(self):
                self.inner = real_sha256()

            def update(self, content):
                self.inner.update(content)
                replacement = artifact.with_name('replacement.age')
                replacement.write_bytes(b'different ciphertext')
                os.replace(replacement, artifact)

            def hexdigest(self):
                return self.inner.hexdigest()

        with patch.object(backup.hashlib, 'sha256', ReplacingHash):
            with self.assertRaisesRegex(backup.BackupError, 'changed during checksum'):
                backup.verify_copy(artifact, expected)


if __name__ == '__main__':
    unittest.main()
