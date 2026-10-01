#!/usr/bin/env bash
set -euo pipefail

DEPLOY="scripts/server/deploy.sh"
DOC="docs/SERVER_DEPLOYMENT.md"

python3 - "$DEPLOY" "$DOC" <<'PY'
import sys
deploy=open(sys.argv[1],encoding="utf-8").read()
doc=open(sys.argv[2],encoding="utf-8").read()

for needle in [
    'status --porcelain=v1 --untracked-files=all',
    'repository has uncommitted or untracked changes',
    'DEPLOYED_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"',
    'printf \'%s\\n\' "$DEPLOYED_COMMIT" > "$ROOT_DIR/DEPLOYED_COMMIT"',
]:
    if needle not in deploy:
        raise SystemExit(f"ERROR: deploy.sh missing reproducibility fragment: {needle}")

for needle in [
    '/opt/funtidesk/DEPLOYED_COMMIT',
    'Фактическая приёмка M1',
]:
    if needle not in doc:
        raise SystemExit(f"ERROR: deployment documentation missing fragment: {needle}")

print("R02_SELFTEST_OK=true")
PY
