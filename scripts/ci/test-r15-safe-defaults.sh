#!/usr/bin/env bash
set -euo pipefail
COMMON="client/src/common.rs"
grep -Fq 'OPTION_DIRECT_SERVER.to_owned(), "N".to_owned()' "$COMMON"
grep -Fq 'OPTION_ENABLE_LAN_DISCOVERY.to_owned(), "N".to_owned()' "$COMMON"
grep -Fq 'OPTION_ALLOW_REMOTE_CONFIG_MODIFICATION.to_owned()' "$COMMON"
grep -Fq 'OPTION_ALLOW_INSECURE_TLS_FALLBACK.to_owned()' "$COMMON"
grep -Fq 'OPTION_APPROVE_MODE.to_owned(), "password".to_owned()' "$COMMON"
grep -Fq '"use-temporary-password".to_owned()' "$COMMON"
grep -Fq 'OPTION_TEMPORARY_PASSWORD_LENGTH.to_owned()' "$COMMON"
grep -Fq 'apply_funtidesk_security_policy();' "$COMMON"
echo "R15_SAFE_DEFAULTS_TEST_OK=true"
