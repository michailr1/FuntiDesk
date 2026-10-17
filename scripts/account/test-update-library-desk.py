#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('library_update', Path(__file__).with_name('update-library-desk.py'))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class LibraryUpdate(unittest.TestCase):
    def test_only_exact_api_image_setting_changes(self):
        original = b'FUNTI_ACCOUNT_KEY_FILE=/private/account.key\r\nFUNTI_ACCOUNT_IMAGE=old\r\nOTHER_IMAGE=keep\r\n'
        image = 'sha256:' + 'a' * 64
        result = update.image_env(original, image)
        self.assertEqual(result, original.replace(b'FUNTI_ACCOUNT_IMAGE=old', ('FUNTI_ACCOUNT_IMAGE=' + image).encode()))
        for broken in [b'OTHER=none\n', original + b'FUNTI_ACCOUNT_IMAGE=duplicate\n']:
            with self.assertRaises(RuntimeError):
                update.image_env(broken, image)
        with self.assertRaises(RuntimeError):
            update.image_env(original, 'other\nSETTING=bad')

    def test_local_environment_removes_only_obsolete_settings(self):
        original = b'OTHER=keep\r\nFUNTI_ACCOUNT_IMAGE=old\r\nFUNTI_ACCOUNT_WITNESS_NAMESPACE=old\r\nFUNTI_ACCOUNT_WITNESS_SUBNET=old\r\nFUNTI_ACCOUNT_RECOVERY_DIRECTORY=/data/recovery\r\n'
        image = 'sha256:' + 'b' * 64
        self.assertEqual(update.local_env(original, image), b'OTHER=keep\r\nFUNTI_ACCOUNT_IMAGE=' + image.encode() + b'\r\n')

    def test_backup_and_migration_preview_preserve_the_current_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / 'current.sqlite3'
            db = sqlite3.connect(source)
            for path in ['account/src/schema.sql', 'account/tests/fixtures/schema-v2.sql', 'account/tests/fixtures/schema-v3-library.sql']:
                db.executescript((update.REPO / path).read_text())
            db.execute("INSERT INTO accounts VALUES('account','test@example.invalid',1000,0)")
            db.execute('UPDATE recovery_state SET revision=21,confirmed=19 WHERE id=1')
            db.commit()
            before = update.content_hashes(db)
            db.close()
            self.assertEqual(update.backup_and_check(source, directory), before)
            for name, expected_version in [('current.sqlite3', 3), ('account.sqlite3.before', 3), ('migration-preview.sqlite3', 4)]:
                copy = sqlite3.connect(directory / name)
                self.assertEqual(copy.execute('PRAGMA user_version').fetchone()[0], expected_version)
                self.assertEqual(update.content_hashes(copy), before)
                copy.close()
            self.assertEqual((directory / 'account.sqlite3.before').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
