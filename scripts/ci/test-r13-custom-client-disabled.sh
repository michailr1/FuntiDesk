#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"
grep -Fq 'FuntiDesk custom-client configuration is disabled' "$COMMON"
grep -Fq 'pub fn read_custom_client(_config: &str)' "$COMMON"
if grep -Fq '5Qbwsde3unUcJBtrx9ZkvUmwFNoExHzpryHuPUdqlWM=' "$COMMON"; then
  echo "ERROR: upstream custom-client trust key remains" >&2
  exit 1
fi
if grep -Fq 'std::fs::read_to_string("./custom.txt")' "$COMMON"; then
  echo "ERROR: custom.txt is still loaded" >&2
  exit 1
fi
echo "R13_CUSTOM_CLIENT_TEST_OK=true"
