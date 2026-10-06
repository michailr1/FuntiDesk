#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FUNTIDESK_PRODUCT_IDENTITY_GUARD_FAIL: $*" >&2
  exit 1
}

cmake='client/flutter/windows/CMakeLists.txt'
rc='client/flutter/windows/runner/Runner.rc'
runner='client/flutter/windows/runner/main.cpp'
windows_channel='client/flutter/windows/runner/flutter_window.cpp'
dart_channel='client/flutter/lib/utils/platform_channel.dart'
relative_mouse='client/flutter/lib/models/relative_mouse_model.dart'
config='client/libs/hbb_common/src/config.rs'
auth_2fa='client/src/auth_2fa.rs'
windows_runtime='client/src/platform/windows.rs'
r21='.github/workflows/r21-windows-clean-build.yml'

for required_file in \
  "$cmake" "$rc" "$runner" "$windows_channel" "$dart_channel" \
  "$relative_mouse" "$config" "$auth_2fa" "$windows_runtime" "$r21"; do
  [[ -f "$required_file" ]] || fail "required product identity file is missing: $required_file"
done

grep -Fq 'project(funtidesk LANGUAGES CXX)' "$cmake" || fail 'Windows CMake project is not FuntiDesk'
grep -Fq 'set(BINARY_NAME "FuntiDesk")' "$cmake" || fail 'Windows product executable is not FuntiDesk.exe'

if grep -Eq 'project\([Rr]ust[Dd]esk|set\(BINARY_NAME[[:space:]]+"[Rr]ust[Dd]esk"\)' "$cmake"; then
  fail 'RustDesk is still used as the Windows product target name'
fi

for required in \
  'VALUE "FileDescription", "FuntiDesk Remote Desktop"' \
  'VALUE "InternalName", "FuntiDesk"' \
  'VALUE "OriginalFilename", "FuntiDesk.exe"' \
  'VALUE "ProductName", "FuntiDesk"'; do
  grep -Fq "$required" "$rc" || fail "missing Windows metadata: $required"
done

if grep -Eq 'VALUE "(FileDescription|InternalName|OriginalFilename|ProductName)",[[:space:]]*"[^"\r\n]*[Rr]ust[Dd]esk' "$rc"; then
  fail 'RustDesk remains in user-visible Windows product metadata'
fi

grep -Fq 'pub const FUNTIDESK_APP_NAME: &str = "FuntiDesk";' "$config" || fail 'FuntiDesk config namespace constant is missing'
grep -Fq 'pub const LEGACY_APP_NAME: &str = "RustDesk";' "$config" || fail 'legacy RustDesk migration boundary is missing'
grep -Fq 'std::wstring app_name = L"FuntiDesk";' "$runner" || fail 'Windows runner fallback app name is not FuntiDesk'
grep -Fq 'const ISSUER: &str = "FuntiDesk";' "$auth_2fa" || fail '2FA issuer is not FuntiDesk'

for channel_file in "$windows_channel" "$dart_channel" "$relative_mouse"; do
  grep -Fq 'org.funtidesk.funtidesk/host' "$channel_file" || fail "FuntiDesk host channel missing from $channel_file"
  if grep -Fq 'org.rustdesk.rustdesk/host' "$channel_file"; then
    fail "legacy RustDesk host channel remains in $channel_file"
  fi
done

grep -Fq '.join("FuntiDeskCustomClientStaging")' "$windows_runtime" || fail 'Windows custom-client staging namespace is not FuntiDesk'
grep -Fq 'let caption = "FuntiDesk Output"' "$windows_runtime" || fail 'Windows runtime message caption is not FuntiDesk'

# The GitHub expression is intentionally matched as literal workflow source text.
# shellcheck disable=SC2016
grep -Fq 'name: funtidesk-windows-x64-${{ github.sha }}' "$r21" || fail 'R21 artifact namespace is not FuntiDesk'

# Intentional compatibility boundary:
# - librustdesk.dll and rustdesk_* exported FFI symbols remain upstream-derived ABI names.
# - legacy RustDesk profile identifiers remain only where required for one-time migration.
# - upstream update-feed filenames (rustdesk-<version>.*) remain until FuntiDesk owns
#   its update endpoint and artifact contract.
# - Cargo package/crate names, rustdesk-org dependencies, upstream links and legal
#   attribution are not product-facing identities.
# This guard deliberately does not ban the word "rustdesk" repository-wide.

echo 'FUNTIDESK_PRODUCT_IDENTITY_GUARD_OK=true'
