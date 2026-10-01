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
grep -Fq 'config::FUNTIDESK_RELAY_SERVER.to_owned()' client/src/client.rs
if grep -Fq 'rs-ny.rustdesk.com' "$CFG"; then
  echo "ERROR: upstream rendezvous fallback remains in production config" >&2
  exit 1
fi
if grep -Fq 'OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=' "$CFG"; then
  echo "ERROR: upstream rendezvous public key remains in production config" >&2
  exit 1
fi
echo "R12_BINDING_TEST_OK=true"
