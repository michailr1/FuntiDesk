#!/usr/bin/env bash
set -euo pipefail

COMPOSE="infra/funtidesk-server/compose.yaml"
DEPLOY="scripts/server/deploy.sh"
VERIFY="scripts/server/verify.sh"

python3 - "$COMPOSE" <<'PY'
import sys, yaml
p=sys.argv[1]
with open(p,encoding="utf-8") as f:
    d=yaml.safe_load(f)
for svc in ("hbbs","hbbr"):
    cmd=d["services"][svc]["command"]
    if "-k" not in cmd or "_" not in cmd:
        raise SystemExit(f"ERROR: {svc} command does not require -k _")
print("R01_COMPOSE_KEY_AUTH_OK=true")
PY

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
