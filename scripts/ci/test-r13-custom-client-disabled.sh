#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"
WINDOWS="client/src/platform/windows.rs"
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
grep -Fq 'upstream custom-client staging is disabled' "$WINDOWS"
if grep -Fq 'crate::load_custom_client();' "$WINDOWS"; then
  echo "ERROR: Windows custom-client staging still invokes load_custom_client" >&2
  exit 1
fi
if grep -Fq 'fs::copy(&custom_txt_path' "$WINDOWS"; then
  echo "ERROR: Windows custom-client staging still copies custom.txt into runtime directory" >&2
  exit 1
fi
echo "R13_CUSTOM_CLIENT_TEST_OK=true"
