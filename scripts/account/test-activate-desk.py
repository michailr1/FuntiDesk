#!/usr/bin/env python3
"""Проверить preflight, фазы отката и HTTP readiness без Docker и серверов."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('activate_desk', Path(__file__).with_name('activate-desk.py'))
activation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activation)


class ActivationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='funti-activation-test-')
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        self.root = directory / 'account'
        self.stage = self.root / 'integration'
        self.stage.mkdir(parents=True)
        self.caddy = directory / 'caddy/Caddyfile'
        self.caddy.parent.mkdir()
        self.base = self.caddy.with_name('docker-compose.yml')
        self.current = directory / 'web/current'
        self.current.parent.mkdir()
        self.previous = directory / 'web/previous'
        self.release = directory / 'web/release'
        self.previous.mkdir()
        self.release.mkdir()
        self.current.symlink_to(self.previous)
        (self.root / 'data').mkdir()
        (self.root / 'data/account.sqlite3').touch()
        (self.root / 'identity').mkdir()
        unix_socket = socket.socket(socket.AF_UNIX)
        self.addCleanup(unix_socket.close)
        unix_socket.bind(str(self.root / 'identity/hbbs.sock'))
        (self.root / 'dns-records.json').write_text('{}')
        self.before = b'original full Caddy configuration\n'
        self.candidate = b'candidate full Caddy configuration\n'
        self.caddy.write_bytes(self.before)
        (self.stage / 'Caddyfile.before').write_bytes(self.before)
        (self.stage / 'Caddyfile.candidate').write_bytes(self.candidate)
        self.record = {
            'sourceCommit': 'b' * 40, 'binarySource': 'a' * 40,
            'webRelease': str(self.release), 'previousWebRoot': str(self.previous),
            'caddyContainerBefore': 'old-caddy', 'caddyImage': 'sha256:caddy',
            'caddyBeforeSha256': hashlib.sha256(self.before).hexdigest(),
            'caddyCandidateSha256': hashlib.sha256(self.candidate).hexdigest(),
            'candidateValidated': True,
        }
        self.save_record()
        for name, value in [('ROOT', self.root), ('CADDY', self.caddy),
                            ('BASE', self.base), ('CURRENT', self.current)]:
            self.enterContext(patch.object(activation, name, value))
        self.enterContext(patch.object(activation.os, 'geteuid', return_value=0))
        self.enterContext(patch.object(activation.socket, 'gethostname', return_value='core.funti.cc'))
        self.private = self.enterContext(patch.object(activation, 'private_request'))
        self.run = self.enterContext(patch.object(activation, 'run', return_value=b''))
        self.preflight = self.enterContext(patch.object(activation, 'verify_caddy'))
        self.ready = self.enterContext(patch.object(activation, 'wait_ready'))
        self.enterContext(patch('builtins.print'))

    def save_record(self):
        (self.stage / 'stage.json').write_text(json.dumps(self.record))

    def recreates(self):
        return [call.args for call in self.run.call_args_list if 'up' in call.args]

    def assert_restored(self):
        self.assertEqual(self.caddy.read_bytes(), self.before)
        self.assertEqual(self.current.readlink(), self.previous)
        self.assertFalse((self.root / 'ACTIVATED').exists())

    def test_corrupted_backup_fails_before_any_mutation(self):
        (self.stage / 'Caddyfile.before').write_bytes(b'corrupted backup')
        with self.assertRaisesRegex(RuntimeError, 'backup checksum mismatch'):
            activation.activate()
        self.private.assert_not_called()
        self.run.assert_not_called()
        self.assert_restored()

    def test_unvalidated_candidate_fails_closed(self):
        self.record['candidateValidated'] = False
        self.save_record()
        with self.assertRaisesRegex(RuntimeError, 'not validated'):
            activation.activate()
        self.run.assert_not_called()
        self.assert_restored()

    def test_first_write_failure_does_not_restart_caddy(self):
        with patch.object(activation, 'write_config', side_effect=OSError('write failed')):
            with self.assertRaises(OSError):
                activation.activate()
        self.assertEqual(self.recreates(), [])
        self.ready.assert_not_called()
        self.assert_restored()

    def test_link_failure_restores_config_without_recreate(self):
        with patch.object(activation, 'switch_link', side_effect=OSError('link failed')):
            with self.assertRaises(OSError):
                activation.activate()
        self.assertEqual(self.recreates(), [])
        self.ready.assert_called_once_with([('https://desk.funti.cc/', 200, b'')])
        self.assert_restored()

    def test_failed_recreate_restores_original_compose_and_https(self):
        self.run.side_effect = [subprocess.TimeoutExpired('docker', 60), b'']
        with self.assertRaises(subprocess.TimeoutExpired):
            activation.activate()
        calls = self.recreates()
        self.assertEqual(len(calls), 2)
        self.assertIn(str(self.stage / 'caddy-account.override.yaml'), calls[0])
        self.assertNotIn(str(self.stage / 'caddy-account.override.yaml'), calls[1])
        self.assertIn('never', calls[0])
        self.assertIn('never', calls[1])
        self.ready.assert_called_once_with([('https://desk.funti.cc/', 200, b'')])
        self.assert_restored()

    def test_interrupted_recreate_also_rolls_back(self):
        self.run.side_effect = [KeyboardInterrupt(), b'']
        with self.assertRaises(KeyboardInterrupt):
            activation.activate()
        self.assertEqual(len(self.recreates()), 2)
        self.assert_restored()

    def test_public_readiness_failure_rolls_back(self):
        self.ready.side_effect = [RuntimeError('HTTPS readiness deadline exceeded'), None]
        with self.assertRaisesRegex(RuntimeError, 'readiness deadline'):
            activation.activate()
        self.assertEqual(len(self.recreates()), 2)
        self.assertEqual(self.ready.call_args.args, ([('https://desk.funti.cc/', 200, b'')],))
        self.assert_restored()

    def test_config_restore_failure_still_restores_link_and_reports_rollback(self):
        write_config = activation.write_config
        writes = []

        def fail_restore(contents):
            writes.append(contents)
            if len(writes) == 2:
                raise OSError('restore failed')
            return write_config(contents)

        self.ready.side_effect = RuntimeError('public check failed')
        with patch.object(activation, 'write_config', side_effect=fail_restore):
            with self.assertRaisesRegex(RuntimeError, 'rollback failed: Caddy configuration restore'):
                activation.activate()
        self.assertEqual(len(self.recreates()), 1)
        self.assertEqual(self.current.readlink(), self.previous)
        self.assertFalse((self.root / 'ACTIVATED').exists())

    def test_failed_rollback_recreate_is_reported(self):
        self.run.side_effect = [b'', RuntimeError('rollback compose failed')]
        self.ready.side_effect = RuntimeError('public check failed')
        with self.assertRaisesRegex(RuntimeError, 'rollback failed: Caddy recreate') as caught:
            activation.activate()
        self.assertEqual(str(caught.exception.__cause__), 'public check failed')
        self.assertEqual(len(self.recreates()), 2)
        self.assert_restored()

    def test_failed_rollback_http_is_reported(self):
        self.ready.side_effect = [RuntimeError('public check failed'), RuntimeError('old site unavailable')]
        with self.assertRaisesRegex(RuntimeError, 'rollback failed: rollback verification'):
            activation.activate()
        self.assertEqual(len(self.recreates()), 2)
        self.assert_restored()

    def test_activation_marker_failure_also_rolls_back(self):
        write_text = Path.write_text

        def fail_marker(path, *args, **kwargs):
            if path.name == 'ACTIVATED':
                write_text(path, 'partial')
                raise OSError('marker write failed')
            return write_text(path, *args, **kwargs)

        with patch.object(Path, 'write_text', fail_marker):
            with self.assertRaises(OSError):
                activation.activate()
        self.assertEqual(len(self.recreates()), 2)
        self.assert_restored()

    def test_success_records_tools_and_binary_sources_after_https(self):
        activation.activate()
        self.assertEqual(len(self.recreates()), 1)
        self.assertEqual(self.caddy.read_bytes(), self.candidate)
        self.assertEqual(self.current.readlink(), self.release)
        marker = json.loads((self.root / 'ACTIVATED').read_text())
        self.assertEqual(marker['sourceCommit'], self.record['sourceCommit'])
        self.assertEqual(marker['binarySource'], self.record['binarySource'])
        self.ready.assert_called_once_with([
            ('https://desk.funti.cc/account/', 200, b'account.js'),
            ('https://desk.funti.cc/api/account/v1/session', 401, b'authentication_required'),
        ])


class ReadinessTests(unittest.TestCase):
    def test_delayed_http_rechecks_site_and_api(self):
        now = [0.0]
        checks = [('https://desk.funti.cc/account/', 200, b'account.js'),
                  ('https://desk.funti.cc/api/account/v1/session', 401, b'authentication_required')]
        with patch.object(activation.time, 'monotonic', side_effect=lambda: now[0]), \
                patch.object(activation.time, 'sleep', side_effect=lambda delay: now.__setitem__(0, now[0] + delay)), \
                patch.object(activation, 'request', side_effect=[OSError('not listening'), None,
                                                               RuntimeError('API warming up'), None, None]) as request:
            activation.wait_ready(checks, timeout=4)
        self.assertEqual(now[0], 2)
        self.assertEqual([call.args[0] for call in request.call_args_list],
                         [checks[0][0], checks[0][0], checks[1][0], checks[0][0], checks[1][0]])

    def test_readiness_stops_at_deadline(self):
        now = [0.0]
        with patch.object(activation.time, 'monotonic', side_effect=lambda: now[0]), \
                patch.object(activation.time, 'sleep', side_effect=lambda delay: now.__setitem__(0, now[0] + delay)), \
                patch.object(activation, 'request', side_effect=OSError('not listening')) as request:
            with self.assertRaisesRegex(RuntimeError, 'deadline exceeded'):
                activation.wait_ready([('https://desk.funti.cc/', 200, b'')], timeout=2)
        self.assertEqual(now[0], 2)
        self.assertEqual(request.call_count, 2)
        self.assertTrue(all(0 < call.kwargs['timeout'] <= 2 for call in request.call_args_list))

    def test_private_client_uses_supplied_network_and_literal_host_argument(self):
        real_popen = subprocess.Popen
        # Simulate nc: send HTTP, then require stdin EOF before exiting. Waiting
        # for process exit before reading stdout would deadlock this real child.
        fake_nc = """import sys
request = b''
while b'\\r\\n\\r\\n' not in request:
    request += sys.stdin.buffer.read(1)
sys.stdout.buffer.write(b'HTTP/1.1 401 Unauthorized\\r\\nContent-Length: 23\\r\\n\\r\\nauthentication_required')
sys.stdout.buffer.flush()
sys.stdin.buffer.read()
"""
        with patch.object(activation.subprocess, 'Popen',
                          side_effect=lambda *args, **kwargs: real_popen([sys.executable, '-c', fake_nc], **kwargs)) as popen:
            activation.private_request('sha256:caddy', '/api/account/v1/session', 401,
                                       b'authentication_required', network='test-network', host='172.31.1.2')
        command = popen.call_args.args[0]
        self.assertEqual(command[command.index('--network') + 1], 'test-network')
        self.assertEqual(command[-1], '172.31.1.2')
        self.assertNotIn('172.31.1.2', command[command.index('-c') + 1])

    def test_private_client_kills_and_reaps_on_timeout(self):
        with patch.object(activation.subprocess, 'Popen') as popen, \
                patch.object(activation.time, 'monotonic', side_effect=[0, 16]):
            client = popen.return_value.__enter__.return_value
            with self.assertRaisesRegex(RuntimeError, 'response incomplete'):
                activation.private_request('sha256:caddy', '/health', 200, b'ok')
        client.kill.assert_called_once()
        client.communicate.assert_called_once()


class CaddyPreflightTests(unittest.TestCase):
    def setUp(self):
        self.record = {'caddyContainerBefore': 'caddy-id', 'caddyImage': 'sha256:caddy'}
        self.base = ['docker', 'compose', '-f', 'base.yaml']
        self.proposed = [*self.base, '-f', 'account.yaml']
        self.info = {'State': {'Running': True}, 'Image': 'sha256:caddy', 'Mounts': [
            {'Destination': '/etc/caddy/Caddyfile', 'Source': str(activation.CADDY), 'Type': 'bind', 'RW': False},
            {'Destination': '/usr/share/caddy', 'Source': str(activation.CURRENT), 'Type': 'bind', 'RW': False},
            {'Destination': '/data', 'Name': 'original-ssl', 'Type': 'volume', 'RW': True},
        ], 'NetworkSettings': {'Networks': {'remnawave-network': {'NetworkID': 'original-network-id'}}},
            'Config': {'Labels': {'com.docker.compose.config-hash': 'original-config-hash'}}}
        self.original = {'services': {'caddy': {
            'image': 'caddy:production', 'networks': {'remnawave-network': {}},
            'volumes': [
                {'target': '/etc/caddy/Caddyfile', 'type': 'bind', 'source': str(activation.CADDY), 'read_only': True},
                {'target': '/usr/share/caddy', 'type': 'bind', 'source': str(activation.CURRENT), 'read_only': True},
                {'target': '/data', 'type': 'volume', 'source': 'ssl'},
            ],
        }}, 'volumes': {'ssl': {'name': 'original-ssl'}},
            'networks': {'remnawave-network': {'name': 'remnawave-network', 'external': True}}}
        self.candidate = copy.deepcopy(self.original)
        self.candidate['services']['caddy']['networks']['funtidesk-account-front'] = {'ipv4_address': '172.31.251.4'}
        self.image_id = 'sha256:caddy'
        self.containers = b'caddy-id\n'
        self.run = self.enterContext(patch.object(activation, 'run', side_effect=self.output))

    def output(self, *args):
        if args[:2] == ('docker', 'ps'):
            return self.containers
        if args[:2] == ('docker', 'inspect'):
            return json.dumps([self.info]).encode()
        if args[:3] == ('docker', 'image', 'inspect'):
            return json.dumps([{'Id': self.image_id}]).encode()
        if args[:3] == ('docker', 'network', 'inspect'):
            return json.dumps([{'Name': 'remnawave-network', 'Id': 'original-network-id'}]).encode()
        if '--hash' in args:
            return b'caddy original-config-hash\n'
        return json.dumps(self.candidate if 'account.yaml' in args else self.original).encode()

    def test_original_image_mounts_ssl_and_network_are_preserved(self):
        activation.verify_caddy(self.record, self.base, self.proposed)

    def test_changed_container_or_image_fails_closed(self):
        for changed in ['container', 'image', 'state']:
            with self.subTest(changed=changed):
                self.containers = b'other-id\n' if changed == 'container' else b'caddy-id\n'
                self.info['Image'] = 'sha256:other' if changed == 'image' else 'sha256:caddy'
                self.info['State']['Running'] = changed != 'state'
                with self.assertRaisesRegex(RuntimeError, 'Live Caddy'):
                    activation.verify_caddy(self.record, self.base, self.proposed)

    def test_changed_bind_mount_fails_closed(self):
        self.info['Mounts'][0]['Source'] = '/some/other/Caddyfile'
        with self.assertRaisesRegex(RuntimeError, 'bind mount'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_base_compose_config_hash_drift_fails_closed(self):
        self.info['Config']['Labels']['com.docker.compose.config-hash'] = 'different-config-hash'
        with self.assertRaisesRegex(RuntimeError, 'differs from the live Caddy configuration'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_changed_ssl_volume_fails_closed(self):
        self.original['volumes']['ssl']['name'] = 'replacement-ssl'
        with self.assertRaisesRegex(RuntimeError, 'Caddy volume'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_base_compose_bind_drift_is_rejected(self):
        for target in ['/etc/caddy/Caddyfile', '/usr/share/caddy']:
            with self.subTest(target=target):
                original = copy.deepcopy(self.original)
                original['services']['caddy']['volumes'] = [
                    {**item, 'source': '/some/other/bind'} if item['target'] == target else item
                    for item in original['services']['caddy']['volumes']]
                with patch.object(self, 'original', original), patch.object(self, 'candidate', copy.deepcopy(original)):
                    with self.assertRaisesRegex(RuntimeError, 'bind source'):
                        activation.verify_caddy(self.record, self.base, self.proposed)

    def test_base_compose_readonly_drift_is_rejected(self):
        self.original['services']['caddy']['volumes'][0]['read_only'] = False
        with self.assertRaisesRegex(RuntimeError, 'changes a live Caddy mount'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_override_cannot_redirect_existing_volume(self):
        self.candidate['volumes']['ssl']['name'] = 'other-ssl'
        with self.assertRaisesRegex(RuntimeError, 'existing volume definition'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_override_cannot_change_existing_settings(self):
        self.candidate['services']['caddy']['image'] = 'other:image'
        with self.assertRaisesRegex(RuntimeError, 'fields other than networks'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_override_cannot_remove_existing_network(self):
        del self.candidate['services']['caddy']['networks']['remnawave-network']
        with self.assertRaisesRegex(RuntimeError, 'existing networks'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_short_network_attachment_and_empty_mapping_are_equivalent(self):
        self.original['services']['caddy']['networks']['remnawave-network'] = None
        activation.verify_caddy(self.record, self.base, self.proposed)

    def test_existing_network_attachment_options_are_still_preserved(self):
        self.original['services']['caddy']['networks']['remnawave-network'] = {'aliases': ['existing-caddy']}
        with self.assertRaisesRegex(RuntimeError, 'existing networks'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_override_cannot_redirect_existing_network_definition(self):
        self.candidate['networks']['remnawave-network']['name'] = 'other-network'
        with self.assertRaisesRegex(RuntimeError, 'existing network definition'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_base_compose_network_name_drift_is_rejected(self):
        self.original['networks']['remnawave-network']['name'] = 'other-network'
        self.candidate['networks']['remnawave-network']['name'] = 'other-network'
        with self.assertRaisesRegex(RuntimeError, 'changes a live Caddy network'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_recreated_physical_network_is_rejected(self):
        self.info['NetworkSettings']['Networks']['remnawave-network']['NetworkID'] = 'different-network-id'
        with self.assertRaisesRegex(RuntimeError, 'network identity'):
            activation.verify_caddy(self.record, self.base, self.proposed)

    def test_retagged_compose_image_fails_closed(self):
        self.image_id = 'sha256:other'
        with self.assertRaisesRegex(RuntimeError, 'replace the staged Caddy image'):
            activation.verify_caddy(self.record, self.base, self.proposed)


if __name__ == '__main__':
    unittest.main()
