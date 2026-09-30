#!/usr/bin/env bash
set -euo pipefail

SERVER_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/root/repo/infra/funtidesk-server" "$TMP/root/data" "$TMP/bin"
cat > "$TMP/root/server.env" <<'EOF'
FUNTIDESK_FQDN=desk.funti.cc
FUNTIDESK_DATA_DIR=/tmp/unused
EOF
printf 'private-fixture\n' > "$TMP/root/data/id_ed25519"
printf 'fixture-public-key\n' > "$TMP/root/data/id_ed25519.pub"
chmod 600 "$TMP/root/data/id_ed25519"
chmod 644 "$TMP/root/data/id_ed25519.pub"
export MOCK_KEY="fixture-public-key"

cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  compose)
    exit 0
    ;;
  inspect)
    echo running
    ;;
  port)
    case "${2:-}" in
      funtidesk-hbbs)
        echo "21115/tcp -> 0.0.0.0:21115"
        echo "21116/tcp -> 0.0.0.0:21116"
        echo "21116/udp -> 0.0.0.0:21116"
        if [[ "${EXTRA_PORT:-0}" == "1" ]]; then
          echo "21118/tcp -> 0.0.0.0:21118"
        fi
        ;;
      funtidesk-hbbr)
        echo "21117/tcp -> 0.0.0.0:21117"
        ;;
    esac
    ;;
  logs)
    echo "Key: ${MOCK_KEY}"
    ;;
  *)
    echo "unexpected docker args: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP/bin/docker"

cat > "$TMP/bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *:21118*|*:21119*)
    exit 0
    ;;
  *)
    echo "LISTEN fixture"
    ;;
esac
EOF
chmod +x "$TMP/bin/ss"

before_hash="$(sha256sum "$TMP/root/data/id_ed25519" "$TMP/root/data/id_ed25519.pub")"
before_modes="$(stat -c '%a %n' "$TMP/root/data/id_ed25519" "$TMP/root/data/id_ed25519.pub")"

for _ in 1 2; do
  PATH="$TMP/bin:$PATH" ROOT_DIR="$TMP/root" REPO_DIR="$TMP/root/repo"     bash "$SERVER_SCRIPTS/verify.sh" >/dev/null
done

after_hash="$(sha256sum "$TMP/root/data/id_ed25519" "$TMP/root/data/id_ed25519.pub")"
after_modes="$(stat -c '%a %n' "$TMP/root/data/id_ed25519" "$TMP/root/data/id_ed25519.pub")"
[[ "$before_hash" == "$after_hash" ]] || { echo "ERROR: verify.sh changed key contents" >&2; exit 1; }
[[ "$before_modes" == "$after_modes" ]] || { echo "ERROR: verify.sh changed key modes" >&2; exit 1; }

if PATH="$TMP/bin:$PATH" ROOT_DIR="$TMP/root" REPO_DIR="$TMP/root/repo" EXTRA_PORT=1   bash "$SERVER_SCRIPTS/verify.sh" >/dev/null 2>&1; then
  echo "ERROR: verify.sh accepted an extra Docker published port" >&2
  exit 1
fi

grep -q 'sshd -T' "$SERVER_SCRIPTS/apply-firewall.sh"
if grep -q 'ufw allow 22/tcp' "$SERVER_SCRIPTS/apply-firewall.sh"; then
  echo "ERROR: apply-firewall.sh still hard-codes SSH/22" >&2
  exit 1
fi

echo "R04_SELFTEST_OK=true"
