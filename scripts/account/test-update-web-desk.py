#!/usr/bin/env python3
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('static_update', Path(__file__).with_name('update-web-desk.py'))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class StaticUpdate(unittest.TestCase):
    def exercise(self, readiness_fails=False, config_changed=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'ACTIVATED').touch()
            (root / 'account.env').write_bytes(b'API_IMAGE=existing\n')
            (root / 'Caddyfile').write_bytes(b'existing shared sites\n')
            (root / 'updates').mkdir()
            (root / 'releases/old').mkdir(parents=True)
            current = root / 'current'
            current.symlink_to(root / 'releases/old')
            old = os.readlink(current)
            caddy = {'Id': 'old-caddy', 'Name': '/caddy', 'Image': 'existing-image',
                     'Config': {'Labels': {'com.docker.compose.project': 'caddy', 'com.docker.compose.service': 'caddy', 'com.docker.compose.config-hash': 'original'}},
                     'State': {'Running': True}, 'Mounts': [{'Destination': '/web', 'RW': False}],
                     'HostConfig': {'PortBindings': {}}, 'NetworkSettings': {'Networks': {'account': {}, 'server': {}}}}
            api = {'Id': 'existing-api', 'Name': '/funtidesk-account-account-1', 'State': {'Running': True}, 'Config': {},
                   'Mounts': [{'Destination': '/data', 'Source': str(root)}],
                   'NetworkSettings': {'Networks': {'funtidesk-account-front': {'IPAddress': '127.0.0.1'}}}}
            recreates = []

            def run(*args):
                if args[0] == 'git':
                    return b'' if args[-1] == '--porcelain' else b'a' * 40
                if args[1] == 'ps':
                    return b'caddy api'
                if args[1] == 'inspect':
                    active = copy.deepcopy(caddy)
                    if recreates:
                        active['Id'] = 'new-caddy'
                    return json.dumps([active, api]).encode()
                if '--hash' in args:
                    return b'caddy changed' if config_changed else b'caddy original'
                self.assertIn('--no-deps', args)
                self.assertEqual(args[-1], 'caddy')
                recreates.append(args)
                return b''

            def switch_link(target):
                current.unlink()
                current.symlink_to(target)

            library = update.load('update-library-desk')
            library.run = run
            library.database_version = lambda _: 4
            library.api_ready = Mock()
            library.stage_full_web = lambda p: p.mkdir()
            activation = SimpleNamespace(switch_link=switch_link, wait_ready=Mock(side_effect=[RuntimeError('readiness'), None] if readiness_fails else None))
            with patch.object(update, 'ROOT', root), patch.object(update, 'CURRENT', current), patch.object(update, 'CADDY', root / 'Caddyfile'), patch.object(update.socket, 'gethostname', return_value='core.funti.cc'), patch.object(update.os, 'geteuid', return_value=0), patch.object(update, 'load', side_effect=lambda name: library if name == 'update-library-desk' else activation), contextlib.redirect_stdout(io.StringIO()):
                if readiness_fails or config_changed:
                    with self.assertRaises(RuntimeError):
                        update.update()
                    self.assertEqual(os.readlink(current), old)
                    self.assertFalse(list((root / 'updates').glob('*/receipt.json')))
                    self.assertEqual(len(recreates), 0 if config_changed else 2)
                else:
                    update.update()
                    receipt = json.loads(next((root / 'updates').glob('*/receipt.json')).read_text())
                    self.assertTrue(receipt['apiAndOtherContainersPreserved'])
                    self.assertEqual(receipt['webroot'], os.readlink(current))
                    self.assertEqual(len(recreates), 1)
                self.assertEqual((root / 'account.env').read_bytes(), b'API_IMAGE=existing\n')
                self.assertEqual((root / 'Caddyfile').read_bytes(), b'existing shared sites\n')

    def test_only_static_release_is_switched(self):
        self.exercise()

    def test_readiness_failure_restores_previous_release(self):
        self.exercise(readiness_fails=True)

    def test_changed_compose_is_rejected_before_switching(self):
        self.exercise(config_changed=True)


if __name__ == '__main__':
    unittest.main()
