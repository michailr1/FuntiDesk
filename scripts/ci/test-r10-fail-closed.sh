#!/usr/bin/env bash
set -euo pipefail
CLIENT="client/src/client.rs"
SERVER="client/src/server.rs"

if grep -Fq 'fall back to non-secure' "$CLIENT"; then
  echo "ERROR: client plaintext fallback remains" >&2
  exit 1
fi
if grep -Fq 'return Ok(option_pk);' "$CLIENT"; then
  echo "ERROR: client still returns success from failed secure handshake" >&2
  exit 1
fi

grep -Fq 'rendezvous server did not provide a signed peer key' "$CLIENT"
grep -Fq 'signed peer id mismatch' "$CLIENT"
grep -Fq 'empty encryption material' "$CLIENT"
grep -Fq 'insecure session rejected by FuntiDesk policy' "$SERVER"
grep -Fq 'empty or invalid peer asymmetric key' "$SERVER"
grep -Fq 'empty peer symmetric key' "$SERVER"

echo "R10_FAIL_CLOSED_TEST_OK=true"
