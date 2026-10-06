#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FUNTIDESK_PRODUCT_IDENTITY_GUARD_FAIL: $*" >&2
  exit 1
}

cmake='client/flutter/windows/CMakeLists.txt'
rc='client/flutter/windows/runner/Runner.rc'
r21='.github/workflows/r21-windows-clean-build.yml'

[[ -f "$cmake" && -f "$rc" && -f "$r21" ]] || fail 'required Windows product files are missing'

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

grep -Fq 'name: funtidesk-windows-x64-${{ github.sha }}' "$r21" || fail 'R21 artifact namespace is not FuntiDesk'

# Intentional compatibility boundary:
# - librustdesk.dll is still the upstream-derived Rust/Flutter bridge library.
# - Cargo package/crate names and upstream attribution are not product-facing
#   identities and are migrated, if useful, in a later vendor/source phase.
# This guard deliberately does not ban the word "rustdesk" repository-wide.

echo 'FUNTIDESK_PRODUCT_IDENTITY_GUARD_OK=true'
