#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('browser_update', Path(__file__).with_name('update-browser-desk.py'))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class BrowserUpdate(unittest.TestCase):
    def test_only_desk_changes_and_existing_account_handler_remains(self):
        before = 'other.example {\n respond "keep"\n}\ndesk.funti.cc {\n handle /api/account/* {\n reverse_proxy api:21800\n }\n handle {\n file_server\n }\n}\nlast.example {\n respond "also keep"\n}\n'
        after = update.browser_config(before, 'handle /connect/* {\n file_server\n}')
        self.assertTrue(after.startswith(before.split('desk.funti.cc')[0]))
        self.assertTrue(after.endswith(before[before.index('last.example'):]))
        self.assertIn('handle /api/account/* {\n reverse_proxy api:21800\n }', after)
        with self.assertRaises(RuntimeError):
            update.browser_config(after, 'anything')

    def test_overlay_can_add_only_the_existing_server_network(self):
        before = {'services': {'caddy': {'image': 'pinned', 'ports': ['443:443'], 'networks': {'account': {'ipv4_address': '172.31.251.4'}}}}, 'networks': {'account': {'name': 'funtidesk-account-front', 'external': True}}}
        after = copy.deepcopy(before)
        after['services']['caddy']['networks']['funtidesk-server'] = {}
        after['networks']['funtidesk-server'] = {'external': True, 'name': 'funtidesk-server'}
        update.network_only(before, after)
        for mutate in [lambda m: m['services']['caddy'].update(image='other'), lambda m: m['services']['caddy'].update(ports=['80:80']), lambda m: m['services']['caddy']['networks'].pop('account')]:
            broken = copy.deepcopy(after)
            mutate(broken)
            with self.assertRaises(RuntimeError):
                update.network_only(before, broken)

    def test_browser_only_package_preserves_old_account_and_rejects_tampering(self):
        def manifest(root, data):
            rows = []
            for name, content in data.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
                rows.append({'file': name, 'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
            (root / 'manifest.json').write_text(json.dumps({'artifacts': rows}))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old, source, release = root / 'old', root / 'source', root / 'release'
            manifest(old, {'account/index.html': b'old account'})
            manifest(source, {'account/index.html': b'new account requiring new API', 'connect/index.html': b'new browser'})
            self.assertEqual(update.stage_files(old, source, release), 2)
            self.assertEqual((release / 'account/index.html').read_bytes(), b'old account')
            self.assertEqual((release / 'connect/index.html').read_bytes(), b'new browser')
            (source / 'connect/index.html').write_bytes(b'tampered')
            with self.assertRaises(RuntimeError):
                update.stage_files(old, source, root / 'unsafe')
            self.assertFalse((root / 'unsafe').exists())


if __name__ == '__main__':
    unittest.main()
