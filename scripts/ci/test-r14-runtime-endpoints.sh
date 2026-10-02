#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"

python3 - "$COMMON" <<'PY'
import sys
s=open(sys.argv[1], encoding="utf-8").read()
a=s.index("pub fn check_software_update()")
b=s.index("#[inline]\npub fn get_app_name()", a)
update=s[a:b]
if "version_check_request" in update or "api.rustdesk.com" in update:
    raise SystemExit("ERROR: upstream update network path remains")

a=s.index("pub fn get_api_server(")
b=s.index("#[inline]\npub fn is_public", a)
api=s[a:b]
if "admin.rustdesk.com" in api or "http://" in api or "https://" in api:
    raise SystemExit("ERROR: runtime API resolver still produces an external URL")
if "String::new()" not in api:
    raise SystemExit("ERROR: API resolver is not fail-closed")
print("R14_RUNTIME_ENDPOINT_TEST_OK=true")
PY

for host in stun.l.google.com stun.cloudflare.com stun.nextcloud.com; do
  grep -Fq "$host" docs/NETWORK_ALLOWLIST.md
done
grep -Fq 'desk.funti.cc:21117' docs/NETWORK_ALLOWLIST.md
