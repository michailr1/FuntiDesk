#!/usr/bin/env python3
"""Проверить HMAC/freshness, закрытые ошибки и выбор закреплённого relay."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('probe_witness_head', Path(__file__).with_name('probe-witness-head.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
KEY = bytes(range(32))
NAMESPACE = '33' * 32
NONCE = '44' * 32


def head(revision=0):
    return {'namespace': NAMESPACE, 'revision': revision, 'event_highwater': revision,
            'digest': '55' * 32 if revision else ''}


def response(nonce=NONCE, value=None):
    reply = {'Head': value if value is not None else head()}
    return {'nonce': nonce, 'reply': reply,
            'mac': probe.tag(KEY, 'witness-response-v1', probe.compact([nonce, reply]))}


class AuthenticationTests(unittest.TestCase):
    def test_length_prefixed_request_hmac_golden_vector(self):
        self.assertEqual(probe.tag(KEY, 'witness-request-v1', probe.compact([NONCE, NAMESPACE, 'Head'])),
                         '105e1d2c8974568d63adc76058bb781fa1e6d12c27eb3874a0cea3e2e498711e')

    def test_valid_reply_ignores_wire_field_order(self):
        value = response()
        value['reply']['Head'] = dict(reversed(list(value['reply']['Head'].items())))
        self.assertEqual(probe.verify_response(json.dumps(value), KEY, NAMESPACE, NONCE, 0), head())

    def test_old_nonce_cannot_be_replayed(self):
        with self.assertRaisesRegex(probe.ProbeError, 'nonce mismatch'):
            probe.verify_response(json.dumps(response()), KEY, NAMESPACE, '66' * 32)

    def test_wrong_mac_or_key_fails_closed(self):
        value = response()
        value['mac'] = '00' * 32
        for raw, key in [(json.dumps(value), KEY), (json.dumps(response()), b'\xff' * 32)]:
            with self.subTest(key=key[0]), self.assertRaisesRegex(probe.ProbeError, 'authentication failed'):
                probe.verify_response(raw, key, NAMESPACE, NONCE)

    def test_signed_wrong_namespace_is_rejected(self):
        wrong = {**head(), 'namespace': '77' * 32}
        with self.assertRaisesRegex(probe.ProbeError, 'namespace'):
            probe.verify_response(json.dumps(response(value=wrong)), KEY, NAMESPACE, NONCE)

    def test_invalid_head_shapes_and_empty_state_are_rejected(self):
        for changed in [{'revision': True}, {'revision': -1}, {'revision': 1 << 63},
                        {'event_highwater': True}, {'event_highwater': 1}, {'digest': '55' * 32},
                        {'unknown': 'hidden'}]:
            with self.subTest(changed=changed), self.assertRaises(probe.ProbeError):
                probe.verify_response(json.dumps(response(value={**head(), **changed})), KEY, NAMESPACE, NONCE)

    def test_duplicate_json_fields_and_unknown_envelope_are_rejected(self):
        for raw in ['{"nonce":"one","nonce":"two"}', json.dumps({**response(), 'extra': 1})]:
            with self.subTest(raw=raw), self.assertRaises(probe.ProbeError):
                probe.verify_response(raw, KEY, NAMESPACE, NONCE)

    def test_expected_zero_rejects_signed_nonempty_witness(self):
        with self.assertRaisesRegex(probe.ProbeError, 'revision differs'):
            probe.verify_response(json.dumps(response(value=head(1))), KEY, NAMESPACE, NONCE, 0)
        self.assertEqual(probe.verify_response(json.dumps(response(value=head(1))), KEY, NAMESPACE, NONCE), head(1))

    def test_each_route_uses_new_nonce_and_only_head(self):
        frames = []

        def reply(endpoint, frame):
            frames.append(copy.deepcopy(frame))
            self.assertEqual(frame['operation'], 'Head')
            self.assertEqual(frame['mac'], probe.tag(KEY, 'witness-request-v1',
                                                    probe.compact([frame['nonce'], NAMESPACE, 'Head'])))
            return json.dumps(response(frame['nonce'])).encode()

        with patch.object(probe.secrets, 'token_hex', side_effect=[NONCE, '66' * 32]), \
                patch.object(probe, 'exchange', side_effect=reply):
            probe.probe(probe.REMOTE, KEY, NAMESPACE, 0)
            probe.probe('http://172.31.252.2:21801/v1/witness', KEY, NAMESPACE, 0)
        self.assertNotEqual(frames[0]['nonce'], frames[1]['nonce'])
        self.assertTrue(all(KEY.hex() not in json.dumps(frame) for frame in frames))

    def test_both_routes_required_and_backwards_head_rejected(self):
        with patch.object(probe, 'load_settings', return_value=(KEY, NAMESPACE, 'subnet')), \
                patch.object(probe, 'relay_endpoint', return_value='relay'), \
                patch.object(probe, 'probe', side_effect=[head(2), head(1)]) as request:
            with self.assertRaisesRegex(probe.ProbeError, 'inconsistently'):
                probe.run_probe(Path('key'), Path('env'))
        self.assertEqual(request.call_count, 2)


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.release = json.loads(probe.RELEASE.read_text())
        self.image = self.release['images']['funtidesk-account']
        self.info = {'running': True, 'image': self.image, 'networks': {
            'private': {'IPAddress': '172.31.252.2', 'NetworkID': 'private-id'},
            'outbound': {'IPAddress': '172.28.0.2', 'NetworkID': 'outbound-id'}}}
        self.internal = True
        self.revision = self.release['source']
        self.subnet = probe.ipaddress.ip_network('172.31.252.0/29')
        self.docker = self.enterContext(patch.object(probe, 'docker', side_effect=self.output))

    def output(self, *args):
        if args[0] == 'ps':
            return b'relay-id\n'
        if args[0] == 'inspect':
            return json.dumps(self.info).encode()
        if args[0] == 'image':
            return self.revision.encode()
        if args[0] == 'network':
            self.assertEqual(args[-1], 'private-id')
            return json.dumps({'internal': self.internal, 'ipam': [{'Subnet': str(self.subnet)}]}).encode()
        raise AssertionError('Unexpected Docker operation')

    def test_selects_private_address_of_pinned_relay(self):
        self.assertEqual(probe.relay_endpoint(self.subnet), 'http://172.31.252.2:21801/v1/witness')

    def test_unknown_image_wrong_revision_or_noninternal_network_are_rejected(self):
        for changed in ['image', 'revision', 'internal']:
            with self.subTest(changed=changed):
                self.info['image'] = 'untrusted' if changed == 'image' else self.image
                self.revision = 'wrong' if changed == 'revision' else self.release['source']
                self.internal = changed != 'internal'
                with self.assertRaises(probe.ProbeError):
                    probe.relay_endpoint(self.subnet)


class TransportAndSettingsTests(unittest.TestCase):
    def test_transport_disables_proxy_and_redirects(self):
        paths = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                paths.append(self.path)
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(303 if self.path == '/redirect' else 200)
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Location', '/head')
                self.end_headers()
                self.wfile.write(b'{}')

            def do_GET(self):
                paths.append(self.path)
                self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        endpoint = 'http://127.0.0.1:' + str(server.server_port)
        with patch.dict(os.environ, {'http_proxy': 'http://127.0.0.1:1', 'HTTP_PROXY': 'http://127.0.0.1:1',
                                     'no_proxy': '', 'NO_PROXY': ''}):
            self.assertEqual(probe.exchange(endpoint + '/head', {}), b'{}')
            with self.assertRaisesRegex(probe.ProbeError, 'transport failed'):
                probe.exchange(endpoint + '/redirect', {})
        self.assertEqual(paths, ['/head', '/redirect'])

    def test_existing_settings_and_duplicate_namespace(self):
        with tempfile.TemporaryDirectory() as temporary:
            key_file, env_file = Path(temporary) / 'key', Path(temporary) / 'env'
            key_file.write_text(KEY.hex() + '\n')
            env_file.write_text('FUNTI_ACCOUNT_WITNESS_NAMESPACE=' + NAMESPACE + '\n')
            key, namespace, subnet = probe.load_settings(key_file, env_file)
            self.assertEqual((key, namespace, str(subnet)), (KEY, NAMESPACE, '172.31.252.0/29'))
            env_file.write_text(env_file.read_text() * 2)
            with self.assertRaisesRegex(probe.ProbeError, 'Duplicate'):
                probe.load_settings(key_file, env_file)

    def test_failure_does_not_print_external_exception_or_secret(self):
        with patch.object(probe.os, 'geteuid', return_value=0), \
                patch.object(probe.socket, 'gethostname', return_value='core.funti.cc'), \
                patch.object(probe, 'run_probe', side_effect=ValueError('sensitive-server-body')), \
                patch('sys.argv', ['probe']), patch('builtins.print') as output:
            self.assertEqual(probe.main(), 1)
        self.assertEqual(output.call_args.args, ('WITNESS_HEAD_PROBE_FAILED: ValueError',))


if __name__ == '__main__':
    unittest.main()
