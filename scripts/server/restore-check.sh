#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" ]] || { echo "usage: $0 <backup.tar.gz>" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "ERROR: archive not found" >&2; exit 1; }

tar -tzf "$ARCHIVE" | grep -qx 'data/id_ed25519'
tar -tzf "$ARCHIVE" | grep -qx 'data/id_ed25519.pub'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -C "$TMP" -xzf "$ARCHIVE" data/id_ed25519 data/id_ed25519.pub

[[ -s "$TMP/data/id_ed25519" ]]
[[ -s "$TMP/data/id_ed25519.pub" ]]

echo "RESTORE_CHECK_OK=true"
