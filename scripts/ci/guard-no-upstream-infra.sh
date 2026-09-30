#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-client}"
[[ -d "$ROOT" ]] || { echo "ERROR: client root not found: $ROOT" >&2; exit 2; }

# FUNTIDESK: enforce the trust boundary on runtime paths that can actually
# choose endpoints/keys or establish sessions. Translation strings and
# upstream parser test fixtures are not network configuration sources.
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

failed=0
for file in "${runtime_files[@]}"; do
  [[ -f "$file" ]] || continue
  for value in "${forbidden[@]}"; do
    if grep -nF -- "$value" "$file" >/dev/null 2>&1; then
      echo "ERROR: forbidden upstream infrastructure value found in $file: $value" >&2
      grep -nF -- "$value" "$file" >&2 || true
      failed=1
    fi
  done
done

if (( failed != 0 )); then
  exit 1
fi

echo "NO_UPSTREAM_INFRA_GUARD_OK=true"
