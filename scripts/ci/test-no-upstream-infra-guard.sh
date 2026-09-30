#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/client/src"
printf 'const SAFE: &str = "desk.funti.cc";\n' > "$TMP/client/src/safe.rs"
bash "$SCRIPT_DIR/guard-no-upstream-infra.sh" "$TMP/client" >/dev/null

printf 'const BAD: &str = "rs-ny.rustdesk.com";\n' > "$TMP/client/src/bad.rs"
if bash "$SCRIPT_DIR/guard-no-upstream-infra.sh" "$TMP/client" >/dev/null 2>&1; then
  echo "ERROR: upstream infrastructure guard accepted forbidden endpoint" >&2
  exit 1
fi

echo "UPSTREAM_INFRA_GUARD_SELFTEST_OK=true"
