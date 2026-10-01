#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"
WINDOWS="client/src/platform/windows.rs"

python3 - "$COMMON" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()

checks=[
    ("pub fn get_custom_rendezvous_server", "#[inline]\npub fn get_api_server"),
    ("pub async fn get_key", "pub fn pk_to_fingerprint"),
]
for start,end in checks:
    a=s.index(start)
    b=s.index(end,a)
    block=s[a:b]
    if "get_license_from_exe_name" in block:
        raise SystemExit(f"ERROR: exe-name infrastructure override remains in {start}")

api_a=s.index("pub fn get_api_server")
api_b=s.index("#[inline]\npub fn is_public",api_a)
if "get_license_from_exe_name" in s[api_a:api_b]:
    raise SystemExit("ERROR: exe-name API override remains")

print("R11_EXE_NAME_CONFIG_TEST_OK=true")
PY

if grep -Fq 'Config::set_option("custom-rendezvous-server".into(), lic.host)' "$WINDOWS"; then
  echo "ERROR: Windows installer still persists exe-derived rendezvous" >&2
  exit 1
fi
if grep -Fq '*config::EXE_RENDEZVOUS_SERVER.write().unwrap() = lic.host.clone();' "$WINDOWS"; then
  echo "ERROR: Windows bootstrap still applies exe-derived rendezvous" >&2
  exit 1
fi
