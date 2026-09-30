#!/usr/bin/env bash
set -euo pipefail

SERVER_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# FUNTIDESK: deterministic structural fixture; no production key material.
dd if=/dev/zero of="$TMP/private.raw" bs=64 count=1 status=none
dd if=/dev/zero of="$TMP/public.raw" bs=32 count=1 status=none
base64 -w0 "$TMP/private.raw" > "$TMP/id_ed25519"
printf '\n' >> "$TMP/id_ed25519"
base64 -w0 "$TMP/public.raw" > "$TMP/id_ed25519.pub"
printf '\n' >> "$TMP/id_ed25519.pub"

"$SERVER_SCRIPTS/validate-keypair.sh" "$TMP/id_ed25519" "$TMP/id_ed25519.pub" | grep -q '^KEYPAIR_CHECK_OK=true$'

cp "$TMP/public.raw" "$TMP/public-bad.raw"
printf '\001' | dd of="$TMP/public-bad.raw" bs=1 seek=0 conv=notrunc status=none
base64 -w0 "$TMP/public-bad.raw" > "$TMP/id_ed25519.bad.pub"
printf '\n' >> "$TMP/id_ed25519.bad.pub"
if "$SERVER_SCRIPTS/validate-keypair.sh" "$TMP/id_ed25519" "$TMP/id_ed25519.bad.pub" >/dev/null 2>&1; then
  echo "ERROR: mismatched key pair was accepted" >&2
  exit 1
fi

printf 'encrypted-artifact-fixture\n' > "$TMP/artifact.age"
(
  cd "$TMP"
  sha256sum artifact.age > artifact.age.sha256
  sha256sum -c artifact.age.sha256 >/dev/null
)
printf 'X' | dd of="$TMP/artifact.age" bs=1 seek=0 conv=notrunc status=none
if (cd "$TMP" && sha256sum -c artifact.age.sha256 >/dev/null 2>&1); then
  echo "ERROR: changed artifact passed checksum" >&2
  exit 1
fi

echo "R03_SELFTEST_OK=true"
