#!/usr/bin/env python3
"""ADR-018: the release keys are the same in every list.

infra/release/allowed_signers is the reference. RELEASE_KEYS in the client
must hold exactly those keys; install.ps1 may be empty (during the switch to
signed releases) or hold exactly those keys.
"""
import base64
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def raw(blob):
    data = base64.b64decode(blob, validate=True)
    if len(data) != 51 or data[:19] != b'\0\0\0\x0bssh-ed25519\0\0\0\x20':
        sys.exit(f'not an ssh-ed25519 key: {blob}')
    return data[19:]


allowed = []
for line in (ROOT / 'infra/release/allowed_signers').read_text().splitlines():
    if line.strip() and not line.lstrip().startswith('#'):
        principal, kind, blob = line.split()[:3]
        if principal != 'funtidesk-release' or kind != 'ssh-ed25519':
            sys.exit(f'unexpected line in allowed_signers: {line}')
        allowed.append(raw(blob))

source = (ROOT / 'client/src/funti_release_sig.rs').read_text()
body = re.search(r'pub const RELEASE_KEYS: &\[\[u8; 32\]\] = &\[(.*?)\n\];', source, re.S)
client = [bytes(int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{2})', group))
          for group in re.findall(r'\[([^\[\]]*)\]', body.group(1) if body else '')]

script = (ROOT / 'install.ps1').read_text()
block = re.search(r'\$releaseKeys = @\((.*?)\)', script, re.S).group(1)
installer = [raw(blob) for blob in re.findall(r'ssh-ed25519 ([A-Za-z0-9+/=]+)', block)]

if not allowed:
    sys.exit('infra/release/allowed_signers has no keys')
if sorted(client) != sorted(allowed):
    sys.exit('RELEASE_KEYS in funti_release_sig.rs differs from allowed_signers')
if installer and sorted(installer) != sorted(allowed):
    sys.exit('$releaseKeys in install.ps1 differs from allowed_signers')
print(f'release keys: {len(allowed)} in allowed_signers and the client; install.ps1 has {len(installer)}')
