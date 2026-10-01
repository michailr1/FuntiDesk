#!/usr/bin/env bash
set -euo pipefail

DEPLOY="scripts/server/deploy.sh"
DOC="docs/SERVER_DEPLOYMENT.md"

grep -Fq 'status --porcelain=v1 --untracked-files=all' "$DEPLOY"
grep -Fq 'repository has uncommitted or untracked changes' "$DEPLOY"
grep -Fq 'DEPLOYED_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"' "$DEPLOY"
grep -Fq 'printf '''%s\n''' "$DEPLOYED_COMMIT" > "$ROOT_DIR/DEPLOYED_COMMIT"' "$DEPLOY"
grep -Fq '/opt/funtidesk/DEPLOYED_COMMIT' "$DOC"
grep -Fq 'Фактическая приёмка M1' "$DOC"

echo "R02_SELFTEST_OK=true"
