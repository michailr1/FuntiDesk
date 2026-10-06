from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LANG = ROOT / "client/src/lang.rs"
AUTH_2FA = ROOT / "client/src/auth_2fa.rs"
CLIPBOARD = ROOT / "client/src/clipboard.rs"
PLATFORM = ROOT / "client/libs/hbb_common/src/platform/mod.rs"
WIN_MAIN = ROOT / "client/flutter/windows/runner/main.cpp"
WIN_WINDOW = ROOT / "client/flutter/windows/runner/flutter_window.cpp"
DART_COMMON = ROOT / "client/flutter/lib/common.dart"


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


old_branding = '''        if !crate::is_rustdesk() {
            if s.contains("RustDesk")
                && !name.starts_with("upgrade_rustdesk_server_pro")
                && name != "powered_by_me"
            {
                let app_name = crate::get_app_name();
                if !app_name.contains("RustDesk") {
                    s = s.replace("RustDesk", &app_name);
                } else {
                    // https://github.com/rustdesk/rustdesk-server-pro/issues/845
                    // If app_name contains "RustDesk" (e.g., "RustDesk-Admin"), we need to avoid
                    // replacing "RustDesk" within the already-substituted app_name, which would
                    // cause duplication like "RustDesk-Admin" -> "RustDesk-Admin-Admin".
                    //
                    // app_name only contains alphanumeric and hyphen.
                    const PLACEHOLDER: &str = "#A-P-P-N-A-M-E#";
                    if !s.contains(PLACEHOLDER) {
                        s = s.replace(&app_name, PLACEHOLDER);
                        s = s.replace("RustDesk", &app_name);
                        s = s.replace(PLACEHOLDER, &app_name);
                    } else {
                        // It's very unlikely to reach here.
                        // Skip replacement to avoid incorrect result.
                    }
                }
            }
        }
'''
new_branding = '''        if s.contains("RustDesk")
            && !name.starts_with("upgrade_rustdesk_server_pro")
            && name != "powered_by_me"
        {
            let app_name = crate::get_app_name();
            if !app_name.contains("RustDesk") {
                s = s.replace("RustDesk", &app_name);
            } else {
                // https://github.com/rustdesk/rustdesk-server-pro/issues/845
                // If app_name contains "RustDesk" (e.g., a legacy custom build), avoid replacing
                // "RustDesk" inside the already-substituted app name and duplicating its suffix.
                const PLACEHOLDER: &str = "#A-P-P-N-A-M-E#";
                if !s.contains(PLACEHOLDER) {
                    s = s.replace(&app_name, PLACEHOLDER);
                    s = s.replace("RustDesk", &app_name);
                    s = s.replace(PLACEHOLDER, &app_name);
                }
            }
        }
'''
replace_once(LANG, old_branding, new_branding, "runtime localization branding")
replace_once(AUTH_2FA, 'const ISSUER: &str = "RustDesk";', 'const ISSUER: &str = "FuntiDesk";', "2FA issuer")
replace_once(CLIPBOARD, '"RustDesk placeholder to clear the file clipboard"', '"FuntiDesk placeholder to clear the file clipboard"', "clipboard placeholder")
replace_once(PLATFORM, '            "RustDesk",\n            &format!("Got signal {} and exit.{}", sig, info),', '            "FuntiDesk",\n            &format!("Got signal {} and exit.{}", sig, info),', "Linux crash dialog")
replace_once(WIN_MAIN, 'std::wstring app_name = L"RustDesk";', 'std::wstring app_name = L"FuntiDesk";', "Windows runner fallback app name")
replace_once(WIN_WINDOW, '"org.rustdesk.rustdesk/host"', '"org.funtidesk.funtidesk/host"', "Windows Flutter host channel")
replace_once(DART_COMMON, 'MethodChannel("org.rustdesk.rustdesk/host")', 'MethodChannel("org.funtidesk.funtidesk/host")', "Dart Flutter host channel")

print("FUNTIDESK_PHASE2_BRANDING_PATCH_OK=true")
