from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def replace_once(rel: str, old: str, new: str, label: str) -> None:
    path = ROOT / rel
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


# Keep the host method-channel coherent across every native/Dart endpoint.
replace_once(
    "client/flutter/lib/models/relative_mouse_model.dart",
    "MethodChannel('org.rustdesk.rustdesk/host')",
    "MethodChannel('org.funtidesk.funtidesk/host')",
    "relative mouse host channel",
)
replace_once(
    "client/flutter/lib/utils/platform_channel.dart",
    'MethodChannel("org.rustdesk.rustdesk/host")',
    'MethodChannel("org.funtidesk.funtidesk/host")',
    "platform host channel",
)
replace_once(
    "client/flutter/lib/utils/platform_channel.dart",
    "/// The platform channel for RustDesk.",
    "/// The platform channel for FuntiDesk.",
    "platform channel comment",
)
replace_once(
    "client/flutter/macos/Runner/MainFlutterWindow.swift",
    'FlutterMethodChannel(name: "org.rustdesk.rustdesk/host"',
    'FlutterMethodChannel(name: "org.funtidesk.funtidesk/host"',
    "macOS host channel",
)

# Product-facing runtime strings.
replace_once(
    "client/flutter/lib/common.dart",
    'debugPrint("Start closing RustDesk...");',
    'debugPrint("Start closing FuntiDesk...");',
    "close debug text",
)
replace_once(
    "client/flutter/lib/desktop/widgets/tabbar_widget.dart",
    'child: const Text(\n                              "RustDesk",',
    'child: const Text(\n                              "FuntiDesk",',
    "desktop tab title",
)

# macOS log prefix only; registrar symbol name remains an internal compatibility identifier.
mac = ROOT / "client/flutter/macos/Runner/MainFlutterWindow.swift"
text = mac.read_text(encoding="utf-8")
count = text.count('[RustDesk]')
if count != 4:
    raise SystemExit(f"macOS RustDesk log prefix: expected exactly four matches, found {count}")
mac.write_text(text.replace('[RustDesk]', '[FuntiDesk]'), encoding="utf-8")

# Windows privacy-mode runtime namespace.
replace_once(
    "client/src/privacy_mode/win_topmost_window.rs",
    '"RuntimeBroker_rustdesk.exe"',
    '"RuntimeBroker_funtidesk.exe"',
    "privacy broker executable",
)
replace_once(
    "client/src/privacy_mode/win_topmost_window.rs",
    '"RustDeskPrivacyWindowClass"',
    '"FuntiDeskPrivacyWindowClass"',
    "privacy window class",
)
replace_once(
    "client/src/privacy_mode/win_topmost_window.rs",
    '"RustDeskPrivacyWindow"',
    '"FuntiDeskPrivacyWindow"',
    "privacy window name",
)

# Windows update cleanup recognizes both new FuntiDesk downloads and old legacy RustDesk downloads.
replace_once(
    "client/src/platform/windows.rs",
    '''                // Match files like rustdesk-*.msi or rustdesk-*.exe
                if file_name.starts_with("rustdesk-")
                    && (file_name.ends_with(".msi") || file_name.ends_with(".exe"))
''',
    '''                // Match current FuntiDesk update files and legacy RustDesk update files.
                if (file_name.starts_with("funtidesk-") || file_name.starts_with("rustdesk-"))
                    && (file_name.ends_with(".msi") || file_name.ends_with(".exe"))
''',
    "Windows update temp cleanup",
)

# Printer diagnostic file is product-owned.
replace_once(
    "client/src/platform/windows.cc",
    'C:\\\\Windows\\\\temp\\\\test_rustdesk.log',
    'C:\\\\Windows\\\\temp\\\\test_funtidesk.log',
    "printer C++ log path",
)
replace_once(
    "client/src/platform/windows.rs",
    'C:\\\\Windows\\\\temp\\\\test_rustdesk.log',
    'C:\\\\Windows\\\\temp\\\\test_funtidesk.log',
    "printer Rust error path",
)

# User-facing plugin prompts only; plugin ABI target names remain compatible.
replace_once(
    "client/src/plugin/callback_ext.rs",
    "please contact the RustDesk team for support.",
    "please contact the FuntiDesk team for support.",
    "plugin support prompt",
)
replace_once(
    "client/src/plugin/manager.rs",
    '"RustDesk wants to install then plugin"',
    '"FuntiDesk wants to install the plugin"',
    "plugin install prompt",
)
replace_once(
    "client/src/plugin/manager.rs",
    '"RustDesk wants to uninstall the plugin"',
    '"FuntiDesk wants to uninstall the plugin"',
    "plugin uninstall prompt",
)

print("FUNTIDESK_PHASE25_PATCH_OK=true")
