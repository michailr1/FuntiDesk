import importlib.util
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('snapshot', Path(__file__).with_name('snapshot.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'account.sqlite'
        self.now = 1800000000
        with sqlite3.connect(self.path) as db:
            for name in ('schema.sql', 'schema-library.sql', 'schema-local.sql'):
                db.executescript((ROOT / 'account/src' / name).read_text())
            db.execute('INSERT INTO accounts VALUES(?,?,?,0)', ('secret-account', 'private@example.test', self.now))
            for i, seen in enumerate((self.now, self.now - m.DAY, self.now - 7*m.DAY, self.now - 30*m.DAY, self.now+1, None)):
                db.execute('INSERT INTO devices VALUES(?,?,?,?,?,?,?,?)',
                           (str(i), 'secret-account', str(i), 'key'+str(i), 'SECRET_NAME', '1.5.0' if i == 0 else '<script>SECRET</script>', self.now, seen))
            db.execute('INSERT INTO connection_history VALUES(?,?,?,?,?,?)', ('secret-account','event','0','target','SECRET', self.now))

    def test_boundaries_and_private_output(self):
        before = self.path.read_bytes()
        r = m.collect(self.path, now=self.now)
        self.assertEqual(r['account']['account_active_devices'], {'1':1,'7':2,'30':3})
        self.assertEqual(r['account']['account_active_accounts'], {'1':1,'7':1,'30':1})
        self.assertEqual(r['account']['account_versions'], {'1.5.0':1,'other_or_unknown':5})
        self.assertEqual(r['account']['retained_reported_connections']['1'], 1)
        self.assertIsNone(r['hbbs'])
        for secret in ('SECRET', 'private@example', 'secret-account', 'target'):
            self.assertNotIn(secret, m.render(r))
        self.assertEqual(before, self.path.read_bytes())

    def test_v5_and_future_schema(self):
        with sqlite3.connect(self.path) as db:
            db.executescript((ROOT / 'account/src/schema-cancel.sql').read_text())
        self.assertEqual(m.collect(self.path, now=self.now)['account']['accounts_existing'], 1)
        with sqlite3.connect(self.path) as db:
            db.execute('PRAGMA user_version=6')
        with self.assertRaises(ValueError):
            m.collect(self.path)

    def test_readonly_and_missing(self):
        with m.database(self.path) as db:
            with self.assertRaises(sqlite3.OperationalError):
                db.execute('DELETE FROM accounts')
        missing = self.path.with_name('missing')
        with self.assertRaises(FileNotFoundError):
            m.collect(missing)
        self.assertFalse(missing.exists())

    def test_hbbs_dedup_and_empty(self):
        p = self.path.with_name('hbbs')
        with sqlite3.connect(p) as db:
            db.execute('CREATE TABLE peer(id TEXT,pk BLOB)')
            db.executemany('INSERT INTO peer VALUES(?,?)', [('1',b'a'),('2',b'a'),('3',b'')])
        self.assertEqual(m.hbbs_metrics(p), {'hbbs_registered_ids':3,'hbbs_distinct_nonempty_keys':1})

    def test_cli_private_and_no_overwrite(self):
        out = self.path.with_name('report.html')
        cmd = [sys.executable, str(Path(m.__file__)), '--account-copy', str(self.path), '--html', str(out)]
        subprocess.run(cmd, check=True)
        self.assertEqual(out.stat().st_mode & 0o777, 0o600)
        before = out.read_bytes()
        self.assertNotEqual(subprocess.run(cmd, capture_output=True).returncode, 0)
        self.assertEqual(out.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
