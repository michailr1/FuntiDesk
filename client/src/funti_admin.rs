//! FUNTIDESK (ADR-023): the administration layer — from a session, the
//! other side sees the state of this computer (processor, memory, system
//! disk) and, if it may control it, the processes, and can end one.
//! The requests arrive in `server/connection.rs` (`funti_admin_request`),
//! which checks who asks and writes ended processes to the journal.

mod autostart_rules;
mod hardware;
mod rules;
#[cfg(windows)]
mod autostart;
#[cfg(windows)]
mod services;

/// A request of the other side: the bar, processes, services (`rules`) or
/// what starts with Windows (`autostart_rules`).
pub enum Request {
    Core(rules::Request),
    Autostart(autostart_rules::Request),
}

impl Request {
    /// The bar is for every session; the rest only for whoever may control.
    pub fn needs_control(&self) -> bool {
        match self {
            Request::Core(r) => r.needs_control(),
            Request::Autostart(_) => true,
        }
    }
}

use hbb_common::{
    log,
    sysinfo::{Disks, Pid, ProcessRefreshKind, System, Users},
};
use rules::Proc;
use std::sync::Mutex;

lazy_static::lazy_static! {
    // Kept between requests: processor load is the change since the last one.
    static ref SYSTEM: Mutex<System> = Mutex::new(System::new());
}

pub fn parse(request: &str) -> Request {
    let autostart = serde_json::from_str::<serde_json::Value>(request)
        .ok()
        .filter(|v| v["op"].as_str().map_or(false, |op| op.starts_with("autostart")));
    match autostart {
        Some(v) => Request::Autostart(autostart_rules::parse_request(&v)),
        None => Request::Core(rules::parse_request(request)),
    }
}

fn handle_autostart(request: &autostart_rules::Request) -> (String, Option<(&'static str, String)>) {
    use autostart_rules::Request as A;
    #[cfg(windows)]
    match request {
        A::List => (autostart::list(), None),
        A::Set(source, name, enabled) => match autostart::set(*source, name, *enabled) {
            Ok(()) => (
                serde_json::json!({"op": "autostart_set", "name": name, "enabled": enabled}).to_string(),
                Some((if *enabled { "autostart-on" } else { "autostart-off" }, name.clone())),
            ),
            Err(error) => (rules::error_json("autostart_set", error).to_string(), None),
        },
        A::Bad => (rules::error_json("autostart", "funti-admin-bad-request").to_string(), None),
    }
    #[cfg(not(windows))]
    match request {
        A::Bad => (rules::error_json("autostart", "funti-admin-bad-request").to_string(), None),
        _ => (rules::error_json("autostart", "funti-admin-windows-only").to_string(), None),
    }
}

fn own_name() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default()
}

/// The disk the system is on: "C:\" (or what SystemDrive says), or "/".
fn system_disk() -> String {
    if cfg!(windows) {
        format!("{}\\", std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned()))
    } else {
        "/".to_owned()
    }
}

fn status() -> String {
    let mut system = SYSTEM.lock().unwrap();
    system.refresh_cpu_usage();
    system.refresh_memory();
    let cpu = system.global_cpu_info().cpu_usage();
    let wanted = system_disk();
    let disks = Disks::new_with_refreshed_list();
    let (disk_used, disk_total) = disks
        .list()
        .iter()
        .find(|d| d.mount_point().to_string_lossy().eq_ignore_ascii_case(&wanted))
        .map(|d| (d.total_space().saturating_sub(d.available_space()), d.total_space()))
        .unwrap_or((0, 0));
    rules::status_json(
        cpu,
        system.used_memory(),
        system.total_memory(),
        disk_used,
        disk_total,
        wanted.trim_end_matches('\\'),
    )
    .to_string()
}

fn processes() -> String {
    let mut system = SYSTEM.lock().unwrap();
    system.refresh_cpu_usage();
    system.refresh_processes_specifics(ProcessRefreshKind::new().with_cpu().with_user());
    let cores = system.cpus().len().max(1) as f32;
    let users = Users::new_with_refreshed_list();
    let list = system
        .processes()
        .iter()
        .map(|(pid, p)| Proc {
            pid: pid.as_u32(),
            name: p.name().to_owned(),
            // sysinfo counts per core; show the share of the whole processor.
            cpu: p.cpu_usage() / cores,
            memory: p.memory(),
            user: p
                .user_id()
                .and_then(|id| users.get_user_by_id(id))
                .map(|u| u.name().to_owned())
                .unwrap_or_default(),
        })
        .collect();
    rules::processes_json(list, &own_name()).to_string()
}

/// Ok(name of the ended process) or Err(translation key of the reason).
fn kill(pid: u32) -> Result<String, &'static str> {
    let mut system = SYSTEM.lock().unwrap();
    system.refresh_processes_specifics(ProcessRefreshKind::new());
    let Some(process) = system.process(Pid::from_u32(pid)) else {
        return Err("funti-admin-not-found");
    };
    let name = process.name().to_owned();
    if rules::protected(pid, &name, &own_name()) {
        return Err("funti-admin-protected");
    }
    if process.kill() {
        log::info!("FuntiDesk admin: ended {} ({})", name, pid);
        Ok(name)
    } else {
        Err("funti-admin-kill-failed")
    }
}

/// The answer (JSON) and, for an action, what goes to the journal: the
/// action and what it was done to. The caller has already checked that
/// `request` is allowed.
pub fn handle(request: &Request) -> (String, Option<(&'static str, String)>) {
    let request = match request {
        Request::Core(r) => r,
        Request::Autostart(a) => return handle_autostart(a),
    };
    match request {
        rules::Request::Status => (status(), None),
        rules::Request::Processes => (processes(), None),
        rules::Request::Info => {
            let info = hardware::info(&mut SYSTEM.lock().unwrap());
            (rules::info_json(&info).to_string(), None)
        }
        rules::Request::Journal => {
            let events = serde_json::from_str::<serde_json::Value>(&crate::funti_journal::read(false))
                .unwrap_or_default();
            (serde_json::json!({"op": "journal", "events": events}).to_string(), None)
        }
        rules::Request::Kill(pid) => match kill(*pid) {
            Ok(name) => (
                serde_json::json!({"op": "kill", "killed": true, "pid": pid, "name": name}).to_string(),
                Some(("kill", format!("{name} ({pid})"))),
            ),
            Err(error) => (rules::error_json("kill", error).to_string(), None),
        },
        #[cfg(windows)]
        rules::Request::Services => (services::list(), None),
        #[cfg(windows)]
        rules::Request::Service(name, action) => match services::act(name, *action) {
            Ok(state) => (
                serde_json::json!({"op": "service", "name": name, "action": action.name(), "state": state})
                    .to_string(),
                Some((
                    match action {
                        rules::ServiceAction::Start => "service-start",
                        rules::ServiceAction::Stop => "service-stop",
                        rules::ServiceAction::Restart => "service-restart",
                    },
                    name.clone(),
                )),
            ),
            Err(error) => (rules::error_json("service", error).to_string(), None),
        },
        #[cfg(not(windows))]
        rules::Request::Services | rules::Request::Service(..) => (
            rules::error_json(request.op(), "funti-admin-windows-only").to_string(),
            None,
        ),
        rules::Request::Bad => (rules::error_json("", "funti-admin-bad-request").to_string(), None),
    }
}
