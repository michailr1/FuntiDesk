#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"

# R-15 rollback (owner decision 2026-10-05): the hard network-exposure locks
# (direct-server, LAN discovery, remote config modification, insecure TLS
# fallback, WebSocket) were removed. These options must NOT be inserted into
# OVERWRITE_SETTINGS, so they stay user-configurable with pre-R-15 defaults.
if grep -Fq 'OPTION_DIRECT_SERVER.to_owned(), "N".to_owned()' "$COMMON"; then
  echo "ERROR: direct-server hard lock remains after R-15 rollback" >&2
  exit 1
fi
if grep -Fq 'OPTION_ENABLE_LAN_DISCOVERY.to_owned(), "N".to_owned()' "$COMMON"; then
  echo "ERROR: LAN discovery hard lock remains after R-15 rollback" >&2
  exit 1
fi
if grep -Fq 'OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION.to_owned(),' "$COMMON"; then
  echo "ERROR: remote-config hard lock remains after R-15 rollback" >&2
  exit 1
fi
if grep -Fq 'OPTION_ALLOW_INSECURE_TLS_FALLBACK.to_owned(),' "$COMMON"; then
  echo "ERROR: insecure TLS hard lock remains after R-15 rollback" >&2
  exit 1
fi
if grep -Fq 'OPTION_ALLOW_WEBSOCKET.to_owned(),' "$COMMON"; then
  echo "ERROR: WebSocket hard lock remains after R-15 rollback" >&2
  exit 1
fi
if grep -Fq 'OVERWRITE_SETTINGS.write().unwrap();' "$COMMON"; then
  echo "ERROR: common.rs still writes OVERWRITE_SETTINGS" >&2
  exit 1
fi

# Clean-install authentication defaults remain in force (owner scope: only
# the exposure locks were rolled back, not the safe auth baseline).
grep -Fq 'OPTION_APPROVE_MODE.to_owned(), "password".to_owned()' "$COMMON"
grep -Fq '"use-temporary-password".to_owned()' "$COMMON"
grep -Fq 'OPTION_TEMPORARY_PASSWORD_LENGTH.to_owned()' "$COMMON"
grep -Fq 'apply_funtidesk_security_policy();' "$COMMON"
# ADR-004: TCP signaling is the default, as a default (not a hard lock).
grep -Fq 'defaults.insert(keys::OPTION_DISABLE_UDP.to_owned(), "Y".to_owned());' "$COMMON"
echo "R15_SAFE_DEFAULTS_TEST_OK=true"