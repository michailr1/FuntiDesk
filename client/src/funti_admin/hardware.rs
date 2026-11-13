//! FUNTIDESK (ADR-024): what this computer is — system, model, board,
//! processor, memory, video and disks — from sysinfo plus what the system
//! keeps about the firmware (Windows: the registry; Linux: /sys/class/dmi).

use super::rules::HostInfo;
use hbb_common::sysinfo::{DiskKind, Disks, System};

/// (maker, model, board) of the computer.
#[cfg(windows)]
fn firmware() -> (String, String, String) {
    use winreg::{enums::*, RegKey};
    let Ok(bios) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags("HARDWARE\\DESCRIPTION\\System\\BIOS", KEY_READ) else {
        return Default::default();
    };
    let get = |name: &str| bios.get_value::<String, _>(name).unwrap_or_default();
    let board = format!("{} {}", get("BaseBoardManufacturer"), get("BaseBoardProduct"));
    (get("SystemManufacturer"), get("SystemProductName"), board.trim().to_owned())
}

#[cfg(target_os = "linux")]
fn firmware() -> (String, String, String) {
    let get = |name: &str| std::fs::read_to_string(format!("/sys/class/dmi/id/{name}")).unwrap_or_default().trim().to_owned();
    let board = format!("{} {}", get("board_vendor"), get("board_name"));
    (get("sys_vendor"), get("product_name"), board.trim().to_owned())
}

#[cfg(not(any(windows, target_os = "linux")))]
fn firmware() -> (String, String, String) {
    Default::default()
}

/// Names of the video adapters.
#[cfg(windows)]
fn gpus() -> Vec<String> {
    use winreg::{enums::*, RegKey};
    const DISPLAY: &str = "SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}";
    let Ok(class) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(DISPLAY, KEY_READ) else {
        return Vec::new();
    };
    class
        .enum_keys()
        .flatten()
        .filter(|k| k.chars().all(|c| c.is_ascii_digit()))
        .filter_map(|k| class.open_subkey_with_flags(&k, KEY_READ).ok()?.get_value::<String, _>("DriverDesc").ok())
        // The adapter of Remote Desktop sessions, not a video card.
        .filter(|name| name != "Microsoft Remote Display Adapter")
        .collect()
}

#[cfg(not(windows))]
fn gpus() -> Vec<String> {
    Vec::new()
}

pub fn info(system: &mut System) -> HostInfo {
    system.refresh_cpu();
    system.refresh_memory();
    let (maker, model, board) = firmware();
    let os = system
        .long_os_version()
        .or_else(|| system.name())
        .unwrap_or_default();
    let cpu = system.cpus().first().map(|c| c.brand().to_owned()).unwrap_or_default();
    let disks = Disks::new_with_refreshed_list()
        .list()
        .iter()
        .filter(|d| d.total_space() > 0)
        .map(|d| {
            let kind = match d.kind() {
                DiskKind::SSD => "SSD",
                DiskKind::HDD => "HDD",
                _ => "",
            };
            (d.mount_point().to_string_lossy().into_owned(), d.total_space(), kind.to_owned())
        })
        .collect();
    HostInfo {
        os,
        hostname: system.host_name().unwrap_or_default(),
        user: crate::platform::get_active_username(),
        uptime: system.uptime(),
        maker,
        model,
        board,
        cpu,
        cores: system.physical_core_count().unwrap_or_default(),
        threads: system.cpus().len(),
        memory: system.total_memory(),
        gpus: gpus(),
        disks,
    }
}
