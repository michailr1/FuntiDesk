#!/usr/bin/env bash
set -euo pipefail

PRIVATE_FILE="${1:-}"
PUBLIC_FILE="${2:-}"
EXPECTED_PUBLIC_KEY="${3:-}"

[[ -f "$PRIVATE_FILE" ]] || { echo "ERROR: private key missing" >&2; exit 1; }
[[ -f "$PUBLIC_FILE" ]] || { echo "ERROR: public key missing" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

base64 -d "$PRIVATE_FILE" > "$TMP/private.raw" 2>/dev/null || {
  echo "ERROR: private key is not valid base64" >&2
  exit 1
}
base64 -d "$PUBLIC_FILE" > "$TMP/public.raw" 2>/dev/null || {
  echo "ERROR: public key is not valid base64" >&2
  exit 1
}

private_size="$(wc -c < "$TMP/private.raw" | tr -d ' ')"
public_size="$(wc -c < "$TMP/public.raw" | tr -d ' ')"
[[ "$private_size" == "64" ]] || { echo "ERROR: private key decoded size=$private_size, expected 64" >&2; exit 1; }
[[ "$public_size" == "32" ]] || { echo "ERROR: public key decoded size=$public_size, expected 32" >&2; exit 1; }

tail -c 32 "$TMP/private.raw" > "$TMP/private.public.raw"
cmp -s "$TMP/private.public.raw" "$TMP/public.raw" || {
  echo "ERROR: private/public server key pair mismatch" >&2
  exit 1
}

actual_public_key="$(tr -d '\r\n' < "$PUBLIC_FILE")"
if [[ -n "$EXPECTED_PUBLIC_KEY" && "$actual_public_key" != "$EXPECTED_PUBLIC_KEY" ]]; then
  echo "ERROR: restored public key does not match EXPECTED_PUBLIC_KEY" >&2
  exit 1
fi

echo "KEYPAIR_CHECK_OK=true"
echo "PUBLIC_KEY=$actual_public_key"
