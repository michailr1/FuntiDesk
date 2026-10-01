#!/usr/bin/env bash
set -euo pipefail

COMPOSE="infra/funtidesk-server/compose.yaml"
DEPLOY="scripts/server/deploy.sh"
VERIFY="scripts/server/verify.sh"

grep -Fq 'command: ["hbbs", "-r", "${FUNTIDESK_FQDN}:21117", "-k", "_"]' "$COMPOSE"
grep -Fq 'command: ["hbbr", "-k", "_"]' "$COMPOSE"
echo "R01_COMPOSE_KEY_AUTH_OK=true"

python3 - "$DEPLOY" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
hbbs=s.index('up -d hbbs')
wait=s.index('id_ed25519.pub', hbbs)
hbbr=s.index('up -d hbbr', wait)
if not (hbbs < wait < hbbr):
    raise SystemExit("ERROR: deploy does not serialize hbbs identity before hbbr")
print("R01_IDENTITY_ORDER_OK=true")
PY

grep -Fq 'for c in funtidesk-hbbs funtidesk-hbbr' "$VERIFY"
grep -Fq 'key mismatch' "$VERIFY"

echo "R01_SELFTEST_OK=true"
