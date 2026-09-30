#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-client}"
[[ -d "$ROOT" ]] || { echo "ERROR: client root not found: $ROOT" >&2; exit 2; }

# FUNTIDESK: only runtime trust/connection sources are security-blocking.
runtime_files=(
  "$ROOT/libs/hbb_common/src/config.rs"
  "$ROOT/src/common.rs"
  "$ROOT/src/client.rs"
  "$ROOT/src/server.rs"
  "$ROOT/src/rendezvous_mediator.rs"
)
forbidden=(
  'rs-ny.rustdesk.com'
  'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw='
  '5Qbwsde3unUcJBtrx9ZkvUmwFNoExHzpryHuPUdqlWM='
)

for file in "${runtime_files[@]}"; do
  [[ -f "$file" ]] || continue
  for value in "${forbidden[@]}"; do
    if grep -Fq -- "$value" "$file"; then
      echo "ERROR: forbidden upstream infrastructure value found in $file: $value" >&2
      grep -nF -- "$value" "$file" >&2 || true
      exit 1
    fi
  done
done

echo "NO_UPSTREAM_INFRA_GUARD_OK=true"
