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
privacy_runtime='client/src/privacy_mode/win_topmost_window.rs'
plugins='client/src/plugin/mod.rs'
android_gradle='client/flutter/android/app/build.gradle'
android_manifest='client/flutter/android/app/src/main/AndroidManifest.xml'
android_boot='client/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/BootReceiver.kt'
ios_info='client/flutter/ios/Runner/Info.plist'
ios_project='client/flutter/ios/Runner.xcodeproj/project.pbxproj'
mac_info='client/flutter/macos/Runner/Configs/AppInfo.xcconfig'
mac_project='client/flutter/macos/Runner.xcodeproj/project.pbxproj'
r21='.github/workflows/r21-windows-clean-build.yml'

for required_file in \
  "$cmake" "$rc" "$runner" "$windows_channel" "$dart_channel" \
  "$relative_mouse" "$config" "$auth_2fa" "$windows_runtime" \
  "$privacy_runtime" "$plugins" "$android_gradle" "$android_manifest" \
  "$android_boot" "$ios_info" "$ios_project" "$mac_info" "$mac_project" "$r21"; do
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
grep -Fq 'create_new(true)' "$config" || fail 'legacy config migration can overwrite an existing FuntiDesk target'
grep -Fq 'legacy config source is a reparse point' "$config" || fail 'Windows reparse-point rejection is missing from legacy migration'
if grep -Fq 'fs::copy(' "$config"; then
  fail 'direct fs::copy remains in config migration; use the hardened legacy copy helper'
fi
test "$(grep -Fc 'Config::copy_legacy_config_file' "$config")" -eq 4 || fail 'auxiliary migrations do not all use the hardened legacy copy helper'
grep -Fq 'Self::copy_legacy_config_file' "$config" || fail 'primary config migration does not use the hardened legacy copy helper'

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

grep -Fq "WIN_TOPMOST_INJECTED_PROCESS_EXE: &'static str = \"RuntimeBroker_funtidesk.exe\"" "$privacy_runtime" || fail 'privacy-mode broker executable namespace is not FuntiDesk'
grep -Fq "PRIVACY_WINDOW_CLASS: &'static str = \"FuntiDeskPrivacyWindowClass\"" "$privacy_runtime" || fail 'privacy-mode window class is not FuntiDesk'
grep -Fq "PRIVACY_WINDOW_NAME: &'static str = \"FuntiDeskPrivacyWindow\"" "$privacy_runtime" || fail 'privacy-mode window name is not FuntiDesk'
if grep -Eq 'RuntimeBroker_rustdesk\.exe|RustDeskPrivacyWindow(Class)?' "$privacy_runtime"; then
  fail 'legacy RustDesk privacy-mode runtime namespace remains'
fi

grep -Fq 'get_plugins_dir_for("FuntiDesk")' "$plugins" || fail 'plugin runtime namespace is not FuntiDesk'
grep -Fq 'Existing legacy plugins remain untouched' "$plugins" || fail 'plugin legacy isolation contract is missing'
if grep -Eq 'copy_plugin_tree_missing|return Ok\(legacy\)|using legacy directory for this run' "$plugins"; then
  fail 'legacy executable plugins must not be copied or used as FuntiDesk runtime state'
fi

# Android product/runtime identity. Kotlin package names remain an intentional
# upstream implementation namespace; the externally visible applicationId does not.
grep -Fq 'applicationId "cc.funti.funtidesk"' "$android_gradle" || fail 'Android applicationId is not FuntiDesk'
grep -Fq 'android:label="FuntiDesk"' "$android_manifest" || fail 'Android app label is not FuntiDesk'
grep -Fq 'android:label="FuntiDesk Input"' "$android_manifest" || fail 'Android accessibility-service label is not FuntiDesk'
grep -Fq 'android:scheme="funtidesk"' "$android_manifest" || fail 'Android URI scheme is not FuntiDesk'
grep -Fq 'android:name="cc.funti.funtidesk.DEBUG_BOOT_COMPLETED"' "$android_manifest" || fail 'Android debug boot action is not FuntiDesk'
grep -Fq 'const val DEBUG_BOOT_COMPLETED = "cc.funti.funtidesk.DEBUG_BOOT_COMPLETED"' "$android_boot" || fail 'Android boot receiver action is not FuntiDesk'
grep -Fq '"FuntiDesk is open"' "$android_boot" || fail 'Android boot toast is not FuntiDesk'
if grep -Eq 'android:(label|scheme)="[^"]*[Rr]ust[Dd]esk|"RustDesk is Open"|com\.carriez\.flutter_hbb\.DEBUG_BOOT_COMPLETED' "$android_manifest" "$android_boot"; then
  fail 'legacy RustDesk Android product/runtime identity remains'
fi

# Apple product/runtime identity. librustdesk static/dynamic libraries remain
# intentional upstream ABI names and are not covered by these checks.
grep -Fq '<string>FuntiDesk</string>' "$ios_info" || fail 'iOS display/bundle name is not FuntiDesk'
grep -Fq '<string>funtidesk</string>' "$ios_info" || fail 'iOS URI scheme is not FuntiDesk'
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = cc.funti.funtidesk;' "$ios_project" || fail 'iOS bundle identifier is not FuntiDesk'
if grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = com.carriez.flutterHbb;' "$ios_project"; then
  fail 'legacy iOS bundle identifier remains'
fi

grep -Fq 'PRODUCT_NAME = FuntiDesk' "$mac_info" || fail 'macOS product name is not FuntiDesk'
grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER = cc.funti.funtidesk' "$mac_info" || fail 'macOS bundle identifier is not FuntiDesk'
grep -Fq 'Copyright © 2026 FuntiDesk contributors.' "$mac_info" || fail 'macOS visible copyright is not FuntiDesk-owned'
grep -Fq 'FuntiDesk.app' "$mac_project" || fail 'macOS app product is not FuntiDesk.app'
if grep -Fq 'RustDesk.app' "$mac_project" || grep -Fq 'com.carriez.flutterHbb' "$mac_info"; then
  fail 'legacy macOS product identity remains'
fi

# The GitHub expression is intentionally matched as literal workflow source text.
# shellcheck disable=SC2016
grep -Fq 'name: funtidesk-windows-x64-${{ github.sha }}' "$r21" || fail 'R21 artifact namespace is not FuntiDesk'

# Intentional compatibility boundary:
# - librustdesk.dll / liblibrustdesk.* and rustdesk_* exported FFI symbols remain
#   upstream-derived ABI names.
# - Android Kotlin package names may remain com.carriez.flutter_hbb as an internal
#   implementation namespace; the external applicationId is cc.funti.funtidesk.
# - legacy RustDesk profile identifiers remain only where required for one-time migration.
# - passive legacy profile data migrates only through the hardened non-overwriting copy helper.
# - legacy executable plugins are retained on disk but are not copied/executed automatically.
# - upstream update-feed filenames (rustdesk-<version>.*) remain until FuntiDesk owns
#   its update endpoint and artifact contract.
# - Cargo package/crate names, rustdesk-org dependencies, upstream links and legal
#   attribution are not product-facing identities.
# This guard deliberately does not ban the word "rustdesk" repository-wide.

echo 'FUNTIDESK_PRODUCT_IDENTITY_GUARD_OK=true'
