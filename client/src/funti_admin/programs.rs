//! FUNTIDESK (ADR-024, stage 5): installed programs from the Uninstall keys
//! (every user, 32-bit, the signed-in user) and their removal. The command
//! is always read again from the registry here, never taken from the window.

use super::programs_rules::{self as rules, Hive, Method, Raw, HIVES};
use std::{
    os::windows::process::CommandExt,
    process::Command,
    time::{Duration, Instant},
};
use winreg::{enums::*, RegKey};

const UNINSTALL: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
const UNINSTALL32: &str = "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const TIMEOUT: Duration = Duration::from_secs(600);

fn root(hive: Hive) -> Option<RegKey> {
    let (base, path) = match hive {
        Hive::Machine => (RegKey::predef(HKEY_LOCAL_MACHINE), UNINSTALL),
        Hive::Machine32 => (RegKey::predef(HKEY_LOCAL_MACHINE), UNINSTALL32),
        Hive::User => (super::autostart::signed_in_user()?.0, UNINSTALL),
    };
    base.open_subkey_with_flags(path, KEY_READ).ok()
}

fn read(key: &RegKey, name: &str) -> Raw {
    let s = |v: &str| key.get_value::<String, _>(v).unwrap_or_default();
    let n = |v: &str| key.get_value::<u32, _>(v).unwrap_or(0);
    Raw {
        key: name.to_owned(),
        name: s("DisplayName"),
        version: s("DisplayVersion"),
        publisher: s("Publisher"),
        install_date: s("InstallDate"),
        size_kb: n("EstimatedSize") as u64,
        uninstall: s("UninstallString"),
        quiet_uninstall: s("QuietUninstallString"),
        system_component: n("SystemComponent") == 1,
        parent: !s("ParentKeyName").is_empty(),
        release_type: s("ReleaseType"),
        windows_installer: n("WindowsInstaller") == 1,
    }
}

pub fn list() -> String {
    let mut entries = Vec::new();
    for hive in HIVES {
        let Some(root) = root(hive) else { continue };
        for name in root.enum_keys().flatten() {
            if let Ok(key) = root.open_subkey_with_flags(&name, KEY_READ) {
                entries.push((hive, read(&key, &name)));
            }
        }
    }
    rules::list_json(&entries).to_string()
}

/// Ok(name of the removed program) or Err(translation key of the reason).
pub fn uninstall(id: &str) -> Result<String, &'static str> {
    let (hive, name) = rules::parse_id(id).ok_or("funti-admin-bad-request")?;
    let key = root(hive)
        .and_then(|r| r.open_subkey_with_flags(&name, KEY_READ).ok())
        .ok_or("funti-admin-not-found")?;
    let raw = read(&key, &name);
    if rules::protected(&raw) {
        return Err("funti-admin-protected");
    }
    let mut command = match rules::method(&raw) {
        Method::Msi(code) => {
            let mut c = Command::new("msiexec.exe");
            c.args(["/x", &code, "/qn", "/norestart"]);
            c
        }
        Method::Quiet(line) => {
            let mut c = Command::new("cmd.exe");
            c.raw_arg(format!("/D /S /C \"{line}\""));
            c
        }
        Method::Manual => return Err("funti-programs-manual"),
    };
    let mut child = command
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|_| "funti-programs-failed")?;
    let deadline = Instant::now() + TIMEOUT;
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(-1),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(250)),
            _ => {
                child.kill().ok();
                return Err("funti-programs-timeout");
            }
        }
    };
    // 0 done; 3010 and 1641: done, a restart finishes it.
    match code {
        0 | 3010 | 1641 => {
            hbb_common::log::info!("FuntiDesk admin: removed {}", raw.name);
            Ok(raw.name.trim().to_owned())
        }
        _ => {
            hbb_common::log::info!("FuntiDesk admin: removing {} ended with {}", raw.name, code);
            Err("funti-programs-failed")
        }
    }
}
