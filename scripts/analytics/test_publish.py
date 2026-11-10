import importlib.util
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publish', Path(__file__).with_name('publish.py'))
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.account = self.dir / 'account.sqlite3'
        self.out = self.dir / 'www'
        self.out.mkdir()
        # A live database in WAL mode with an open writer, as in production.
        self.live = sqlite3.connect(self.account)
        self.addCleanup(self.live.close)
        self.live.execute('PRAGMA journal_mode=WAL')
        for name in ('schema.sql', 'schema-library.sql', 'schema-local.sql', 'schema-cancel.sql'):
            self.live.executescript((ROOT / 'account/src' / name).read_text())
        self.live.execute("INSERT INTO accounts VALUES('a','private@example.test',1800000000,0)")
        self.live.commit()

    def run_cli(self, *args):
        return subprocess.run([sys.executable, '-I', str(Path(__file__).with_name('publish.py')), *args],
                              capture_output=True, text=True)

    def test_report_from_live_wal_database_replaces_the_old_one(self):
        (self.out / 'index.html').write_text('old')
        before = self.account.read_bytes()
        result = self.run_cli('--account-db', str(self.account), '--out-dir', str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)
        page = (self.out / 'index.html').read_text()
        self.assertIn('&quot;accounts_existing&quot;: 1', page)
        self.assertNotIn('private@example.test', page)
        self.assertEqual(stat.S_IMODE((self.out / 'index.html').stat().st_mode), 0o644)
        self.assertEqual(self.account.read_bytes(), before)
        # No copies or temporary files left behind.
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ['index.html'])

    def test_failure_keeps_the_previous_report_and_logs_no_details(self):
        (self.out / 'index.html').write_text('old')
        result = self.run_cli('--account-db', str(self.dir / 'missing.sqlite3'), '--out-dir', str(self.out))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.out / 'index.html').read_text(), 'old')
        self.assertNotIn('missing.sqlite3', result.stderr)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ['index.html'])


if __name__ == '__main__':
    unittest.main()
