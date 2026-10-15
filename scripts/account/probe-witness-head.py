#!/usr/bin/env python3
"""Проверить свежий подписанный Head с Core напрямую по TLS и через relay."""
import argparse
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import subprocess
import urllib.request

ROOT = Path('/opt/funtidesk-account')
RELEASE = Path(__file__).resolve().parents[2] / 'infra/funtidesk-account/account-release.json'
REMOTE = 'https://de.funti.cc:8447/v1/witness'
MAX_RESPONSE = 65536


class ProbeError(RuntimeError):
    """Сообщения этого типа не содержат закрытых данных или ответов сервера."""


def compact(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=False)


def token(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def tag(key, purpose, value):
    mac = hmac.new(key, digestmod=hashlib.sha256)
    for item in (purpose, value):
        raw = item.encode('utf-8')
        mac.update(len(raw).to_bytes(8, 'big'))
        mac.update(raw)
    return mac.hexdigest()


def load_settings(key_file, env_file):
    values = {}
    for line in env_file.read_text().splitlines():
        name, separator, value = line.strip().partition('=')
        if separator and name in {'FUNTI_ACCOUNT_WITNESS_NAMESPACE', 'FUNTI_ACCOUNT_WITNESS_SUBNET'}:
            if name in values:
                raise ProbeError('Duplicate witness setting')
            values[name] = value.strip().strip('\"\'')
    namespace = values.get('FUNTI_ACCOUNT_WITNESS_NAMESPACE')
    encoded_key = key_file.read_text().strip()
    if not token(namespace) or not token(encoded_key):
        raise ProbeError('Invalid existing witness key or namespace')
    subnet = ipaddress.ip_network(values.get('FUNTI_ACCOUNT_WITNESS_SUBNET', '172.31.252.0/29'))
    if subnet.version != 4 or not subnet.is_private:
        raise ProbeError('Invalid private witness subnet')
    return bytes.fromhex(encoded_key), namespace, subnet


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def exchange(endpoint, frame):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    request = urllib.request.Request(endpoint, data=compact(frame).encode(),
                                     headers={'Content-Type': 'application/json'}, method='POST')
    try:
        with opener.open(request, timeout=20) as response:
            if response.status != 200 or response.headers.get('Cache-Control') != 'no-store':
                raise ProbeError('Witness HTTP status or cache policy mismatch')
            raw = response.read(MAX_RESPONSE + 1)
    except ProbeError:
        raise
    except Exception:
        raise ProbeError('Witness transport failed') from None
    if len(raw) > MAX_RESPONSE:
        raise ProbeError('Witness response too large')
    return raw


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ProbeError('Duplicate witness response field')
        result[name] = value
    return result


def verify_response(raw, key, namespace, nonce, expected_revision=None):
    try:
        response = json.loads(raw, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        raise ProbeError('Invalid witness JSON response') from None
    if (not isinstance(response, dict) or set(response) != {'nonce', 'reply', 'mac'}
            or response['nonce'] != nonce or not token(response['mac'])):
        raise ProbeError('Witness response envelope or nonce mismatch')
    reply = response['reply']
    if not isinstance(reply, dict) or set(reply) != {'Head'}:
        raise ProbeError('Witness did not return Head')
    head = reply['Head']
    if (not isinstance(head, dict) or set(head) != {'namespace', 'revision', 'event_highwater', 'digest'}
            or head['namespace'] != namespace
            or type(head['revision']) is not int or head['revision'] < 0
            or type(head['event_highwater']) is not int or head['event_highwater'] < 0
            or head['revision'] > (1 << 63) - 1 or head['event_highwater'] > (1 << 63) - 1):
        raise ProbeError('Invalid witness Head or namespace')
    if ((head['revision'] == 0 and (head['event_highwater'] != 0 or head['digest'] != ''))
            or (head['revision'] > 0 and not token(head['digest']))):
        raise ProbeError('Invalid witness Head state')
    # Rust signs the declared struct field order, independently of JSON wire order.
    ordered_head = {name: head[name] for name in ('namespace', 'revision', 'event_highwater', 'digest')}
    expected_mac = tag(key, 'witness-response-v1', compact([nonce, {'Head': ordered_head}]))
    if not hmac.compare_digest(response['mac'], expected_mac):
        raise ProbeError('Witness response authentication failed')
    if expected_revision is not None and head['revision'] != expected_revision:
        raise ProbeError('Witness revision differs from expected')
    return ordered_head


def probe(endpoint, key, namespace, expected_revision=None):
    nonce = secrets.token_hex(32)
    frame = {'nonce': nonce, 'namespace': namespace, 'operation': 'Head'}
    frame['mac'] = tag(key, 'witness-request-v1', compact([nonce, namespace, 'Head']))
    return verify_response(exchange(endpoint, frame), key, namespace, nonce, expected_revision)


def docker(*arguments):
    result = subprocess.run(['docker', *arguments], capture_output=True, timeout=15, check=False)
    if result.returncode:
        raise ProbeError('Witness relay Docker inspection failed')
    return result.stdout


def relay_endpoint(subnet):
    containers = docker('ps', '--filter', 'label=com.docker.compose.project=funtidesk-account',
                        '--filter', 'label=com.docker.compose.service=witness-relay',
                        '--format', '{{.ID}}').decode().split()
    if len(containers) != 1:
        raise ProbeError('Expected one running witness relay')
    template = ('{"running":{{json .State.Running}},"image":{{json .Image}},'
                '"networks":{{json .NetworkSettings.Networks}}}')
    info = json.loads(docker('inspect', '--format', template, containers[0]))
    release = json.loads(RELEASE.read_text())
    allowed = {release['images']['funtidesk-account'], release['oci_images']['funtidesk-account']}
    if info['running'] is not True or info['image'] not in allowed:
        raise ProbeError('Witness relay is not the pinned running image')
    revision = docker('image', 'inspect', '--format',
                      '{{index .Config.Labels "org.opencontainers.image.revision"}}', info['image']).decode().strip()
    if revision != release['source']:
        raise ProbeError('Witness relay source revision mismatch')
    candidates = [network for network in info['networks'].values()
                  if network.get('IPAddress') and ipaddress.ip_address(network['IPAddress']) in subnet]
    if len(candidates) != 1:
        raise ProbeError('Witness relay private address is ambiguous or absent')
    network = candidates[0]
    details = json.loads(docker('network', 'inspect', '--format',
                                '{"internal":{{json .Internal}},"ipam":{{json .IPAM.Config}}}',
                                network['NetworkID']))
    if (details['internal'] is not True
            or not any(ipaddress.ip_network(item['Subnet']) == subnet for item in details['ipam'])):
        raise ProbeError('Witness relay network is not the expected internal subnet')
    return 'http://' + network['IPAddress'] + ':21801/v1/witness'


def run_probe(key_file, env_file, expected_revision=None):
    key, namespace, subnet = load_settings(key_file, env_file)
    direct = probe(REMOTE, key, namespace, expected_revision)
    relayed = probe(relay_endpoint(subnet), key, namespace, expected_revision)
    if (relayed['revision'] < direct['revision'] or relayed['event_highwater'] < direct['event_highwater']
            or (relayed['revision'] == direct['revision'] and relayed != direct)):
        raise ProbeError('Witness Head changed inconsistently between routes')
    return relayed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key-file', type=Path, default=ROOT / 'secrets/witness.key')
    parser.add_argument('--env-file', type=Path, default=ROOT / 'account.env')
    parser.add_argument('--expected-revision', type=int)
    args = parser.parse_args()
    try:
        if os.geteuid() != 0 or socket.gethostname() != 'core.funti.cc':
            raise ProbeError('Witness probe must run as root on Core')
        if args.expected_revision is not None and args.expected_revision < 0:
            raise ProbeError('Expected revision must be nonnegative')
        head = run_probe(args.key_file, args.env_file, args.expected_revision)
    except Exception as error:
        reason = str(error) if isinstance(error, ProbeError) else type(error).__name__
        print('WITNESS_HEAD_PROBE_FAILED: ' + reason)
        return 1
    print('WITNESS_FRESH_HEAD_OK direct_tls=verified relay=verified revision='
          + str(head['revision']) + ' event_highwater=' + str(head['event_highwater']))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
