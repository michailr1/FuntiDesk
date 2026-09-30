#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"
python3 - "$COMMON" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
for fn,nextfn in [
    ("pub fn get_custom_rendezvous_server","#[inline]\npub fn get_api_server"),
    ("fn get_api_server_","pub fn get_audit_server"),
    ("pub async fn get_key","pub fn pk_to_fingerprint"),
]:
    a=s.index(fn)
    b=s.index(nextfn,a)
    block=s[a:b]
    if "get_license_from_exe_name" in block:
        raise SystemExit(f"ERROR: exe-name infrastructure override remains in {fn}")
print("R11_EXE_NAME_CONFIG_TEST_OK=true")
PY
