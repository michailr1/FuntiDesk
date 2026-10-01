#!/usr/bin/env bash
set -euo pipefail
CFG="client/libs/hbb_common/src/config.rs"
COMMON="client/src/common.rs"
grep -Fq 'pub const FUNTIDESK_RENDEZVOUS_SERVER: &str = "desk.funti.cc";' "$CFG"
grep -Fq 'pub const FUNTIDESK_RELAY_SERVER: &str = "desk.funti.cc";' "$CFG"
grep -Fq 'pub const FUNTIDESK_SERVER_PUBLIC_KEY: &str = "2R3kWM1HR3BMoz3EB6KDmv5SjOKrDEVdrZXRcFWaDg4=";' "$CFG"
grep -Fq 'format!("{FUNTIDESK_RENDEZVOUS_SERVER}:{RENDEZVOUS_PORT}")' "$CFG"
grep -Fq 'vec![FUNTIDESK_RENDEZVOUS_SERVER.to_owned()]' "$CFG"
grep -Fq 'config::FUNTIDESK_SERVER_PUBLIC_KEY.to_owned()' "$COMMON"
grep -Fq 'get_rs_pk(config::FUNTIDESK_SERVER_PUBLIC_KEY)' "$COMMON"
grep -Fq 'get_rs_pk(config::FUNTIDESK_SERVER_PUBLIC_KEY)' client/src/client.rs
if grep -Fq 'let trust_key = if key.is_empty()' client/src/client.rs; then
  echo "ERROR: peer handshake still accepts caller-provided trust key override" >&2
  exit 1
fi
grep -Fq 'config::FUNTIDESK_RELAY_SERVER.to_owned()' client/src/client.rs
grep -Fq 'config::FUNTIDESK_RELAY_SERVER.to_owned()' client/src/rendezvous_mediator.rs
if grep -Fq 'Config::get_option("relay-server")' client/src/rendezvous_mediator.rs; then
  echo "ERROR: incoming relay path still consults mutable relay-server config" >&2
  exit 1
fi
python3 - <<'PY'
from pathlib import Path
for p in [Path("client/src/rendezvous_mediator.rs"), Path("client/src/common.rs")]:
    s=p.read_text(encoding="utf-8")
    if '"rendezvous-servers".to_owned()' in s and "Config::set_option" in s:
        # Narrow to exact legacy persistence form rather than rejecting unrelated tests/constants.
        if 'Config::set_option(\n                    "rendezvous-servers".to_owned()' in s:
            raise SystemExit(f"ERROR: {p} still persists server-provided rendezvous endpoints")
print("R12_SERVER_LIST_PERSISTENCE_TEST_OK=true")
PY
if grep -Fq 'rs-ny.rustdesk.com' "$CFG"; then
  echo "ERROR: upstream rendezvous fallback remains in production config" >&2
  exit 1
fi
if grep -Fq 'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=' "$CFG"; then
  echo "ERROR: upstream rendezvous public key remains in production config" >&2
  exit 1
fi
echo "R12_BINDING_TEST_OK=true"
