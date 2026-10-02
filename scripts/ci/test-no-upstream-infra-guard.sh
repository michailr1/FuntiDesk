#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/client/libs/hbb_common/src" "$TMP/client/src"
printf 'pub const SAFE: &str = "desk.funti.cc";\n' > "$TMP/client/libs/hbb_common/src/config.rs"
printf 'pub fn safe() {}\n' > "$TMP/client/src/common.rs"
printf 'pub fn safe() {}\n' > "$TMP/client/src/client.rs"
printf 'pub fn safe() {}\n' > "$TMP/client/src/server.rs"
printf 'pub fn safe() {}\n' > "$TMP/client/src/rendezvous_mediator.rs"

bash "$SCRIPT_DIR/guard-no-upstream-infra.sh" "$TMP/client" >/dev/null

printf 'pub const BAD: &str = "rs-ny.rustdesk.com";\n' >> "$TMP/client/libs/hbb_common/src/config.rs"
if bash "$SCRIPT_DIR/guard-no-upstream-infra.sh" "$TMP/client" >/dev/null 2>&1; then
  echo "ERROR: upstream infrastructure guard accepted forbidden rendezvous endpoint" >&2
  exit 1
fi

sed -i '/rs-ny\.rustdesk\.com/d' "$TMP/client/libs/hbb_common/src/config.rs"
printf 'pub const BAD_API: &str = "api.rustdesk.com";\n' >> "$TMP/client/src/common.rs"
if bash "$SCRIPT_DIR/guard-no-upstream-infra.sh" "$TMP/client" >/dev/null 2>&1; then
  echo "ERROR: upstream infrastructure guard accepted forbidden runtime API endpoint" >&2
  exit 1
fi

# A literal used only by a terminal #[cfg(test)] module is allowed.
cat > "$TMP/client/src/common.rs" <<'EOF'
pub fn safe() {}
#[cfg(test)]
mod tests {
    const REJECTED_FIXTURE: &str = "api.rustdesk.com";
}
EOF
bash "$SCRIPT_DIR/guard-no-upstream-infra.sh" "$TMP/client" >/dev/null

echo "UPSTREAM_INFRA_GUARD_SELFTEST_OK=true"
