#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" ]] || { echo "usage: $0 <backup.tar.gz>" >&2; exit 2; }
[[ -f "$ARCHIVE" ]] || { echo "ERROR: archive not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Проверяем архив без pipeline под pipefail: извлекаем только обязательные
# identity-файлы и затем валидируем их наличие/непустое содержимое.
tar -C "$TMP" -xzf "$ARCHIVE" data/id_ed25519 data/id_ed25519.pub

[[ -s "$TMP/data/id_ed25519" ]] || { echo "ERROR: private key missing or empty" >&2; exit 1; }
[[ -s "$TMP/data/id_ed25519.pub" ]] || { echo "ERROR: public key missing or empty" >&2; exit 1; }

echo "RESTORE_CHECK_OK=true"
