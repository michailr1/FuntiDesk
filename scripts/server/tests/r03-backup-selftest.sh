#!/usr/bin/env bash
set -euo pipefail

SERVER_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

for cmd in age age-keygen base64 sha256sum dd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing test dependency: $cmd" >&2; exit 1; }
done

mkdir -p "$ROOT/data" "$ROOT/backups"

# Structural RustDesk Ed25519 fixture expected by validate-keypair.sh:
# 64-byte private value whose trailing 32 bytes are the public value.
head -c 64 /dev/urandom > "$ROOT/private.raw"
tail -c 32 "$ROOT/private.raw" > "$ROOT/public.raw"
base64 -w0 "$ROOT/private.raw" > "$ROOT/data/id_ed25519"
printf '\n' >> "$ROOT/data/id_ed25519"
base64 -w0 "$ROOT/public.raw" > "$ROOT/data/id_ed25519.pub"
printf '\n' >> "$ROOT/data/id_ed25519.pub"

age-keygen -o "$ROOT/owner.agekey" >/dev/null 2>&1
recipient="$(age-keygen -y "$ROOT/owner.agekey")"
expected="$(tr -d '\r\n' < "$ROOT/data/id_ed25519.pub")"

ALLOW_NON_ROOT_TEST=1 ROOT_DIR="$ROOT" AGE_RECIPIENT="$recipient"   bash "$SERVER_SCRIPTS/backup.sh" > "$ROOT/backup.out"

archive="$(awk -F= '/^BACKUP=/{print $2}' "$ROOT/backup.out")"
[[ -f "$archive" && -f "$archive.sha256" ]] || {
  echo "ERROR: encrypted backup or checksum sidecar missing" >&2
  exit 1
}
if find "$ROOT/backups" -maxdepth 1 -type f -name '*.tar.gz' | grep -q .; then
  echo "ERROR: persistent plaintext backup artifact remains" >&2
  exit 1
fi

AGE_IDENTITY_FILE="$ROOT/owner.agekey" EXPECTED_PUBLIC_KEY="$expected"   bash "$SERVER_SCRIPTS/restore-check.sh" "$archive" | grep -q '^RESTORE_CHECK_OK=true$'

# Tampering must fail before/while decrypting.
cp "$archive" "$ROOT/tampered.tar.gz.age"
cp "$archive.sha256" "$ROOT/tampered.tar.gz.age.sha256"
printf 'X' | dd of="$ROOT/tampered.tar.gz.age" bs=1 seek=16 conv=notrunc status=none
if AGE_IDENTITY_FILE="$ROOT/owner.agekey" EXPECTED_PUBLIC_KEY="$expected"   bash "$SERVER_SCRIPTS/restore-check.sh" "$ROOT/tampered.tar.gz.age" >/dev/null 2>&1; then
  echo "ERROR: tampered encrypted backup was accepted" >&2
  exit 1
fi

# A mismatched server identity must be rejected before backup.
cp "$ROOT/data/id_ed25519.pub" "$ROOT/data/id_ed25519.pub.good"
head -c 32 /dev/urandom | base64 -w0 > "$ROOT/data/id_ed25519.pub"
printf '\n' >> "$ROOT/data/id_ed25519.pub"
if ALLOW_NON_ROOT_TEST=1 ROOT_DIR="$ROOT" AGE_RECIPIENT="$recipient"   bash "$SERVER_SCRIPTS/backup.sh" >/dev/null 2>&1; then
  echo "ERROR: mismatched server key pair was backed up" >&2
  exit 1
fi
mv "$ROOT/data/id_ed25519.pub.good" "$ROOT/data/id_ed25519.pub"

echo "R03_SELFTEST_OK=true"
