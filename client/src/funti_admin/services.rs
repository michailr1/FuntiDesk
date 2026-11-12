//! FUNTIDESK (ADR-023, stage 2): Windows services — the list (names from
//! the registry, state and shown name from the service manager) and start,
//! stop, restart.

use super::rules::{self, ServiceAction, Svc};
use std::{thread::sleep, time::Duration};
use windows_service::{
    service::{ServiceAccess, ServiceState},
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use winreg::{enums::*, RegKey};

const SERVICES_KEY: &str = "SYSTEM\\CurrentControlSet\\Services";
/// SERVICE_WIN32_OWN_PROCESS | SERVICE_WIN32_SHARE_PROCESS: not drivers.
const WIN32_SERVICE: u32 = 0x30;
/// A per-user service template (its instances have a suffix of their own).
const USER_SERVICE_TEMPLATE: u32 = 0x40 | 0x80;

fn own_service() -> String {
    crate::get_app_name()
}

fn state_name(state: ServiceState) -> &'static str {
    match state {
        ServiceState::Running => "running",
        ServiceState::Stopped => "stopped",
        ServiceState::StartPending | ServiceState::ContinuePending => "starting",
        ServiceState::StopPending | ServiceState::PausePending => "stopping",
        ServiceState::Paused => "paused",
    }
}

pub fn list() -> String {
    let Ok(manager) = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT) else {
        return rules::error_json("services", "funti-admin-services-failed").to_string();
    };
    let Ok(root) = RegKey::predef(HKEY_LOCAL_MACHINE).open_subkey_with_flags(SERVICES_KEY, KEY_READ) else {
        return rules::error_json("services", "funti-admin-services-failed").to_string();
    };
    let mut list = Vec::new();
    for name in root.enum_keys().flatten() {
        let Ok(key) = root.open_subkey_with_flags(&name, KEY_READ) else { continue };
        let kind: u32 = key.get_value("Type").unwrap_or(0);
        if kind & WIN32_SERVICE == 0 || kind & USER_SERVICE_TEMPLATE == USER_SERVICE_TEMPLATE {
            continue;
        }
        let start: u32 = key.get_value("Start").unwrap_or(3);
        let delayed = key.get_value::<u32, _>("DelayedAutostart").unwrap_or(0) == 1;
        let Ok(service) = manager.open_service(&name, ServiceAccess::QUERY_STATUS | ServiceAccess::QUERY_CONFIG) else {
            continue;
        };
        let state = service.query_status().map(|s| state_name(s.current_state)).unwrap_or("");
        let shown = service
            .query_config()
            .map(|c| c.display_name.to_string_lossy().into_owned())
            .ok()
            .or_else(|| key.get_value::<String, _>("DisplayName").ok())
            .filter(|d| !d.starts_with('@'))
            .unwrap_or_default();
        list.push(Svc { name, display: shown, state, start: rules::start_type(start, delayed) });
    }
    rules::services_json(list, &own_service()).to_string()
}

/// Waits until the service reaches `want` (up to 30 s).
fn wait(service: &windows_service::service::Service, want: ServiceState) -> bool {
    for _ in 0..60 {
        if matches!(service.query_status(), Ok(s) if s.current_state == want) {
            return true;
        }
        sleep(Duration::from_millis(500));
    }
    false
}

/// Ok(state after the action) or Err(translation key of the reason).
pub fn act(name: &str, action: ServiceAction) -> Result<&'static str, &'static str> {
    if rules::service_protected(name, &own_service()) {
        return Err("funti-admin-service-protected");
    }
    let known = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(format!("{SERVICES_KEY}\\{name}"), KEY_READ)
        .map(|k| k.get_value::<u32, _>("Type").unwrap_or(0) & WIN32_SERVICE != 0)
        .unwrap_or(false);
    if !known {
        return Err("funti-admin-service-not-found");
    }
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .map_err(|_| "funti-admin-service-failed")?;
    let service = manager
        .open_service(name, ServiceAccess::QUERY_STATUS | ServiceAccess::START | ServiceAccess::STOP)
        .map_err(|_| "funti-admin-service-failed")?;
    let stop = |service: &windows_service::service::Service| {
        let running = !matches!(service.query_status(), Ok(s) if s.current_state == ServiceState::Stopped);
        !running || (service.stop().is_ok() && wait(service, ServiceState::Stopped))
    };
    let start = |service: &windows_service::service::Service| {
        service.start::<&str>(&[]).is_ok() && wait(service, ServiceState::Running)
    };
    let ok = match action {
        ServiceAction::Start => start(&service),
        ServiceAction::Stop => stop(&service),
        ServiceAction::Restart => stop(&service) && start(&service),
    };
    if !ok {
        return Err("funti-admin-service-failed");
    }
    hbb_common::log::info!("FuntiDesk admin: service {} {}", name, action.name());
    Ok(service.query_status().map(|s| state_name(s.current_state)).unwrap_or(""))
}
