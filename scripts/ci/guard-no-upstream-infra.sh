#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-client}"
[[ -d "$ROOT" ]] || { echo "ERROR: client root not found: $ROOT" >&2; exit 2; }

# FUNTIDESK: only runtime trust/connection sources are security-blocking.
# Literal upstream endpoints are permitted in #[cfg(test)] modules when they
# exist solely to prove rejection/classification behavior.
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
  'api.rustdesk.com'
  'admin.rustdesk.com'
)

scan_runtime_only() {
  local file="$1"
  # In these reviewed files, the unit-test module is terminal. Stop scanning at
  # its #[cfg(test)] marker so negative-test fixtures do not trip the runtime guard.
  awk '/^[[:space:]]*#\[cfg\(test\)\][[:space:]]*$/ { exit } { print }' "$file"
}

for file in "${runtime_files[@]}"; do
  [[ -f "$file" ]] || continue
  runtime_text="$(scan_runtime_only "$file")"
  for value in "${forbidden[@]}"; do
    if grep -Fq -- "$value" <<<"$runtime_text"; then
      echo "ERROR: forbidden upstream infrastructure value found in runtime portion of $file: $value" >&2
      grep -nF -- "$value" <<<"$runtime_text" >&2 || true
      exit 1
    fi
  done
done

echo "NO_UPSTREAM_INFRA_GUARD_OK=true"
