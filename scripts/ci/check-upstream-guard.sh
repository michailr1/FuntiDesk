#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(git rev-parse --show-toplevel)}"
MARKER="$ROOT_DIR/client/.funtidesk-production-locked"

if [[ ! -f "$MARKER" ]]; then
  echo "UPSTREAM_GUARD_PENDING_M2=true"
  exit 0
fi

upstream_server='rs-ny.rustdesk.com'
upstream_key_a='OeVuKk5nlHiXp+APN'
upstream_key_b='n0Y3pC1Iwpwn44JGqrQCsWqmBw='
custom_key_a='5Qbwsde3unUcJBtr'
custom_key_b='x9ZkvUmwFNoExHzpryHuPUdqlWM='
patterns=(
  "$upstream_server"
  "$upstream_key_a$upstream_key_b"
  "$custom_key_a$custom_key_b"
)

failed=0
for pattern in "${patterns[@]}"; do
  matches="$(
    grep -R -n -F       --exclude-dir=.git       --exclude='*.patch'       --exclude='*.diff'       -- "$pattern" "$ROOT_DIR/client" 2>/dev/null || true
  )"
  matches="$(printf '%s\n' "$matches" | grep -Ev '/(test|tests|testdata|fixtures)/' || true)"
  if [[ -n "$matches" ]]; then
    echo "ERROR: forbidden upstream production value remains" >&2
    printf '%s\n' "$matches" >&2
    failed=1
  fi
done

[[ "$failed" -eq 0 ]] || exit 1
echo "UPSTREAM_GUARD_OK=true"
