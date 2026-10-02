#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
IDENTITY_FILE="${AGE_IDENTITY_FILE:-}"
EXPECTED_PUBLIC_KEY="${EXPECTED_PUBLIC_KEY:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -n "$ARCHIVE" ]] || { echo "usage: AGE_IDENTITY_FILE=/path/to/key.txt $0 <backup.tar.gz.age>" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "ERROR: archive not found" >&2; exit 1; }
[[ -f "$ARCHIVE.sha256" ]] || { echo "ERROR: checksum file not found: $ARCHIVE.sha256" >&2; exit 1; }
[[ -n "$IDENTITY_FILE" && -f "$IDENTITY_FILE" ]] || { echo "ERROR: AGE_IDENTITY_FILE must point to the owner age identity" >&2; exit 1; }

for cmd in age sha256sum tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# FUNTIDESK: reject corrupted encrypted artifacts before decryption.
(
  cd "$(dirname "$ARCHIVE")"
  sha256sum -c "$(basename "$ARCHIVE").sha256"
)

age --decrypt -i "$IDENTITY_FILE" -o "$TMP/backup.tar.gz" "$ARCHIVE"
tar -C "$TMP" -xzf "$TMP/backup.tar.gz" data/id_ed25519 data/id_ed25519.pub

[[ -s "$TMP/data/id_ed25519" ]] || { echo "ERROR: private key missing or empty" >&2; exit 1; }
[[ -s "$TMP/data/id_ed25519.pub" ]] || { echo "ERROR: public key missing or empty" >&2; exit 1; }

# FUNTIDESK: verify RustDesk's encoded private/public identity pair before restore.
key_check="$("$SCRIPT_DIR/validate-keypair.sh"   "$TMP/data/id_ed25519"   "$TMP/data/id_ed25519.pub"   "$EXPECTED_PUBLIC_KEY")"
printf '%s\n' "$key_check"

echo "RESTORE_CHECK_OK=true"
