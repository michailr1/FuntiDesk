#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/funtidesk}"
DATA_DIR="$ROOT_DIR/data"
BACKUP_DIR="$ROOT_DIR/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RECIPIENT="${AGE_RECIPIENT:-}"
OUT="$BACKUP_DIR/funtidesk-server-$STAMP.tar.gz.age"
TMP_ARCHIVE=""

if [[ "${EUID}" -ne 0 && "${ALLOW_NON_ROOT_TEST:-0}" != "1" ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

command -v age >/dev/null 2>&1 || { echo "ERROR: age is not installed" >&2; exit 1; }
[[ -n "$RECIPIENT" ]] || { echo "ERROR: AGE_RECIPIENT is required" >&2; exit 1; }
[[ -f "$DATA_DIR/id_ed25519" ]] || { echo "ERROR: no server identity to back up" >&2; exit 1; }
[[ -f "$DATA_DIR/id_ed25519.pub" ]] || { echo "ERROR: no server public key to back up" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/validate-keypair.sh" "$DATA_DIR/id_ed25519" "$DATA_DIR/id_ed25519.pub" >/dev/null

install -d -m 0700 "$BACKUP_DIR"
TMP_ARCHIVE="$(mktemp "$BACKUP_DIR/.funtidesk-server-XXXXXX.tar.gz")"
trap '[[ -n "$TMP_ARCHIVE" ]] && rm -f "$TMP_ARCHIVE"' EXIT

# FUNTIDESK: plaintext backup is temporary and is encrypted before becoming an artifact.
tar -C "$ROOT_DIR" -czf "$TMP_ARCHIVE" data
chmod 600 "$TMP_ARCHIVE"
age -r "$RECIPIENT" -o "$OUT" "$TMP_ARCHIVE"
chmod 600 "$OUT"
(
  cd "$BACKUP_DIR"
  sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256"
)
chmod 600 "$OUT.sha256"
rm -f "$TMP_ARCHIVE"
TMP_ARCHIVE=""

echo "BACKUP_OK=true"
echo "BACKUP=$OUT"
echo "SHA256_FILE=$OUT.sha256"
