#!/usr/bin/env bash
set -euo pipefail

COMPOSE="infra/funtidesk-server/compose.yaml"
DEPLOY="scripts/server/deploy.sh"
VERIFY="scripts/server/verify.sh"

python3 - "$COMPOSE" "$DEPLOY" "$VERIFY" <<'PY'
import sys
compose=open(sys.argv[1],encoding="utf-8").read()
deploy=open(sys.argv[2],encoding="utf-8").read()
verify=open(sys.argv[3],encoding="utf-8").read()

required_compose = [
    'command: ["hbbs", "-r", "${FUNTIDESK_FQDN}:21117", "-k", "_"]',
    'command: ["hbbr", "-k", "_"]',
]
for needle in required_compose:
    if needle not in compose:
        raise SystemExit(f"ERROR: missing key-auth compose fragment: {needle}")

hbbs=deploy.index('up -d hbbs')
wait=deploy.index('id_ed25519.pub', hbbs)
hbbr=deploy.index('up -d hbbr', wait)
if not (hbbs < wait < hbbr):
    raise SystemExit("ERROR: deploy does not serialize hbbs identity before hbbr")

for needle in [
    'for c in funtidesk-hbbs funtidesk-hbbr',
    'key mismatch',
]:
    if needle not in verify:
        raise SystemExit(f"ERROR: verify.sh missing key verification fragment: {needle}")

print("R01_COMPOSE_KEY_AUTH_OK=true")
print("R01_IDENTITY_ORDER_OK=true")
print("R01_SELFTEST_OK=true")
PY
