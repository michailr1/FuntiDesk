#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-client}"

[[ -d "$ROOT" ]] || { echo "ERROR: client root not found: $ROOT" >&2; exit 2; }

forbidden=(
  'rs-ny.rustdesk.com'
  'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw='
  '5Qbwsde3unUcJBtrx9ZkvUmwFNoExHzpryHuPUdqlWM='
)

failed=0
for value in "${forbidden[@]}"; do
  matches="$(
    grep -RInF       --exclude-dir=.git       --exclude-dir=target       --exclude='*.md'       --exclude='*test*'       -- "$value" "$ROOT" 2>/dev/null || true
  )"
  if [[ -n "$matches" ]]; then
    echo "ERROR: forbidden upstream infrastructure value found: $value" >&2
    printf '%s\n' "$matches" >&2
    failed=1
  fi
done

if (( failed != 0 )); then
  exit 1
fi

echo "NO_UPSTREAM_INFRA_GUARD_OK=true"
