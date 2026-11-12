//! FUNTIDESK (ADR-023, stage 2b): what starts with Windows, for every user
//! and for the signed-in one, and switching an entry off or on the way
//! Task Manager does it (the "StartupApproved" mark); nothing is deleted.

use super::autostart_rules::{self as rules, Entry, Source, SOURCES};
use std::path::PathBuf;
use winreg::{enums::*, RegKey, RegValue};

const RUN: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN32: &str = "Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run";
const APPROVED: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved";
const PROFILES: &str = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList";

/// The signed-in user's hive (HKEY_USERS\<SID>) and profile folder. This
/// process runs as the service account, so HKEY_CURRENT_USER is not theirs.
fn signed_in_user() -> Option<(RegKey, PathBuf)> {
    let home = crate::platform::get_active_user_home()?;
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned());
    let profiles = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(PROFILES, KEY_READ).ok()?;
    let sid = profiles.enum_keys().flatten().find(|sid| {
        profiles
            .open_subkey_with_flags(sid, KEY_READ)
            .and_then(|k| k.get_value::<String, _>("ProfileImagePath"))
            .map(|path| rules::same_profile(&path, &home.to_string_lossy(), &drive))
            .unwrap_or(false)
    })?;
    let hive = RegKey::predef(HKEY_USERS).open_subkey_with_flags(&sid, KEY_READ | KEY_WRITE).ok()?;
    Some((hive, home))
}

fn folder(source: Source, home: Option<&PathBuf>) -> Option<PathBuf> {
    const TAIL: &str = "Microsoft\\Windows\\Start Menu\\Programs\\Startup";
    match source {
        Source::CommonFolder => {
            Some(PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_owned())).join(TAIL))
        }
        Source::UserFolder => home.map(|h| h.join("AppData\\Roaming").join(TAIL)),
        _ => None,
    }
}

/// The hive an entry of `source` lives in.
fn hive(source: Source, user: Option<&RegKey>) -> Option<RegKey> {
    if source.per_user() {
        user.map(|u| u.open_subkey_with_flags("", KEY_READ | KEY_WRITE).ok()).flatten()
    } else {
        Some(RegKey::predef(HKEY_LOCAL_MACHINE))
    }
}

fn is_enabled(hive: &RegKey, source: Source, name: &str) -> bool {
    let mark = hive
        .open_subkey_with_flags(format!("{APPROVED}\\{}", source.approved_key()), KEY_READ)
        .and_then(|k| k.get_raw_value(name))
        .ok();
    rules::enabled(mark.as_ref().map(|m| m.bytes.as_slice()))
}

/// (name, command) of every entry of `source`.
fn entries(source: Source, hive: &RegKey, home: Option<&PathBuf>) -> Vec<(String, String)> {
    match source {
        Source::Machine | Source::User | Source::Machine32 => {
            let path = if source == Source::Machine32 { RUN32 } else { RUN };
            let Ok(key) = hive.open_subkey_with_flags(path, KEY_READ) else { return Vec::new() };
            key.enum_values()
                .flatten()
                .map(|(name, _)| {
                    let command = key.get_value::<String, _>(&name).unwrap_or_default();
                    (name, command)
                })
                .filter(|(name, _)| !name.is_empty())
                .collect()
        }
        Source::CommonFolder | Source::UserFolder => {
            let Some(dir) = folder(source, home) else { return Vec::new() };
            std::fs::read_dir(dir)
                .map(|items| {
                    items
                        .flatten()
                        .filter(|f| f.path().is_file())
                        .map(|f| (f.file_name().to_string_lossy().into_owned(), f.path().to_string_lossy().into_owned()))
                        .filter(|(name, _)| !name.eq_ignore_ascii_case("desktop.ini"))
                        .collect()
                })
                .unwrap_or_default()
        }
    }
}

pub fn list() -> String {
    let user = signed_in_user();
    let home = user.as_ref().map(|u| &u.1);
    let mut list = Vec::new();
    for source in SOURCES {
        let Some(hive) = hive(source, user.as_ref().map(|u| &u.0)) else { continue };
        for (name, command) in entries(source, &hive, home) {
            let enabled = is_enabled(&hive, source, &name);
            list.push(Entry { source, name, command, enabled });
        }
    }
    rules::list_json(list, &crate::get_app_name()).to_string()
}

fn filetime_now() -> u64 {
    let since_unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    (since_unix + 11_644_473_600) * 10_000_000
}

/// Switches one entry off or on. Ok(()) or Err(translation key).
pub fn set(source: Source, name: &str, enabled: bool) -> Result<(), &'static str> {
    if rules::protected(name, &crate::get_app_name()) {
        return Err("funti-admin-autostart-protected");
    }
    let user = signed_in_user();
    let hive = hive(source, user.as_ref().map(|u| &u.0)).ok_or("funti-admin-autostart-failed")?;
    let home = user.as_ref().map(|u| &u.1);
    if !entries(source, &hive, home).iter().any(|(n, _)| n == name) {
        return Err("funti-admin-autostart-not-found");
    }
    let (key, _) = hive
        .create_subkey(format!("{APPROVED}\\{}", source.approved_key()))
        .map_err(|_| "funti-admin-autostart-failed")?;
    key.set_raw_value(name, &RegValue { bytes: rules::mark(enabled, filetime_now()), vtype: REG_BINARY })
        .map_err(|_| "funti-admin-autostart-failed")?;
    hbb_common::log::info!("FuntiDesk admin: autostart {} {} {}", source.id(), name, enabled);
    Ok(())
}
