#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/funtidesk}"
DATA_DIR="$ROOT_DIR/data"
BACKUP_DIR="$ROOT_DIR/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BACKUP_DIR/funtidesk-server-$STAMP.tar.gz"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

install -d -m 0700 "$BACKUP_DIR"
[[ -f "$DATA_DIR/id_ed25519" ]] || { echo "ERROR: no server identity to back up" >&2; exit 1; }

tar -C "$ROOT_DIR" -czf "$OUT" data
chmod 600 "$OUT"
sha256sum "$OUT" > "$OUT.sha256"
chmod 600 "$OUT.sha256"

echo "BACKUP_OK=true"
echo "BACKUP=$OUT"
echo "SHA256_FILE=$OUT.sha256"
