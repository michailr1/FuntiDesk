#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/client/src"
touch "$TMP/client/.funtidesk-production-locked"
printf '%s\n' 'const BAD: &str = "rs-ny.rustdesk.com";' > "$TMP/client/src/bad.rs"

if ROOT_DIR="$TMP" bash "$SCRIPT_DIR/check-upstream-guard.sh" >/dev/null 2>&1; then
  echo "ERROR: guard accepted a forbidden upstream endpoint" >&2
  exit 1
fi

rm "$TMP/client/src/bad.rs"
ROOT_DIR="$TMP" bash "$SCRIPT_DIR/check-upstream-guard.sh" | grep -q '^UPSTREAM_GUARD_OK=true$'

echo "R20_GUARD_SELFTEST_OK=true"
