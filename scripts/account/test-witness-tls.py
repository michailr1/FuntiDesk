#!/usr/bin/env python3
"""Проверить отказ неверным сертификатам и откат при неуспешном reload."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("witness_tls", Path(__file__).with_name("sync-witness-tls.py"))
tls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tls)


def certificate(directory, name, hostname):
    cert, key = directory / (name + ".crt"), directory / (name + ".key")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                    "-subj", "/CN=" + hostname, "-addext", "subjectAltName=DNS:" + hostname,
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
    key.chmod(0o600)
    return cert, key


class Publication(unittest.TestCase):
    def test_fsync_failure_after_link_swap_never_leaves_current_target_missing(self):
        with tempfile.TemporaryDirectory(prefix="funti-tls-fsync-") as temporary:
            root = Path(temporary)
            original, key = certificate(root, "original", "de.funti.cc")
            changed, changed_key = certificate(root, "changed", "de.funti.cc")
            directory = root / "tls"
            with patch.object(tls, "running_caddy", return_value=None):
                tls.synchronize(original, key, directory, ca_file=original)
            sync = tls.sync_directory
            for fail_rollback in [False, True]:
                calls = []
                def fault(path):
                    calls.append(path)
                    if len(calls) == 2 or (fail_rollback and len(calls) == 3):
                        raise OSError("fixture directory fsync failed")
                    return sync(path)
                with patch.object(tls, "running_caddy", return_value=None), \
                        patch.object(tls, "sync_directory", side_effect=fault):
                    with self.assertRaises(OSError):
                        tls.synchronize(changed, changed_key, directory, ca_file=changed)
                self.assertEqual((directory / "fullchain.pem").read_bytes(), original.read_bytes())
                self.assertTrue((directory / "privkey.pem").is_file())
                self.assertFalse(list(directory.glob(".current-*")))

    def test_bad_pair_hostname_permissions_and_reload_failure_preserve_active_certificate(self):
        with tempfile.TemporaryDirectory(prefix="funti-tls-unit-") as temporary:
            root = Path(temporary)
            original, key = certificate(root, "original", "de.funti.cc")
            changed, changed_key = certificate(root, "changed", "de.funti.cc")
            wrong, wrong_key = certificate(root, "wrong", "other.example.invalid")
            directory = root / "tls"
            with patch.object(tls, "running_caddy", return_value=None):
                tls.synchronize(original, key, directory, ca_file=original)
            current = (directory / "current").readlink()
            for cert, private, ca in [(changed, key, changed), (wrong, wrong_key, wrong)]:
                with self.assertRaises(RuntimeError):
                    tls.synchronize(cert, private, directory, ca_file=ca)
                self.assertEqual((directory / "current").readlink(), current)
            changed_key.chmod(0o644)
            with self.assertRaises(RuntimeError):
                tls.synchronize(changed, changed_key, directory, ca_file=changed)
            changed_key.chmod(0o600)
            with patch.object(tls, "running_caddy", return_value="own-container"), \
                    patch.object(tls, "reload_caddy", side_effect=RuntimeError("fixture reload failed")):
                with self.assertRaises(RuntimeError):
                    tls.synchronize(changed, changed_key, directory, ca_file=changed)
            self.assertEqual((directory / "current").readlink(), current)
            self.assertEqual((directory / "fullchain.pem").read_bytes(), original.read_bytes())
            self.assertFalse(list(directory.glob(".stage-*")))
            with patch.object(tls, "running_caddy", return_value="own-container"), \
                    patch.object(tls, "reload_caddy") as reload:
                self.assertEqual(tls.synchronize(changed, changed_key, directory, ca_file=changed), "updated and reloaded")
                reload.assert_called_once_with("own-container")
            with patch.object(tls, "running_caddy", return_value="own-container"), \
                    patch.object(tls, "reload_caddy") as reload:
                self.assertEqual(tls.synchronize(changed, changed_key, directory, ca_file=changed), "unchanged and reloaded")
                reload.assert_called_once_with("own-container")
            self.assertEqual(len(list(directory.glob("generation-*"))), 2)
            self.assertEqual((directory / "privkey.pem").stat().st_mode & 0o777, 0o600)
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
