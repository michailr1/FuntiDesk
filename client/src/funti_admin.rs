//! FUNTIDESK (ADR-023): the administration layer — from a session, the
//! other side sees the state of this computer (processor, memory, system
//! disk) and, if it may control it, the processes, and can end one.
//! The requests arrive in `server/connection.rs` (`funti_admin_request`),
//! which checks who asks and writes ended processes to the journal.

mod attention_rules;
mod autostart_rules;
mod eventlog_rules;
mod hardware;
mod programs_rules;
mod rules;
mod run_rules;
mod screen_rules;
mod storage_rules;
#[cfg(windows)]
mod attention;
#[cfg(windows)]
mod autostart;
#[cfg(windows)]
mod eventlog;
#[cfg(windows)]
mod programs;
#[cfg(windows)]
mod run;
#[cfg(windows)]
mod screen;
#[cfg(windows)]
mod services;
#[cfg(windows)]
mod storage;

/// A request of the other side: the bar, processes, services (`rules`),
/// what starts with Windows (`autostart_rules`) or a Windows event log
/// (`eventlog_rules`; None: a request we do not know).
pub enum Request {
    Core(rules::Request),
    Autostart(autostart_rules::Request),
    EventLog(Option<eventlog_rules::Request>),
    /// A picture of the screen this wide (ADR-024, stage 3a).
    Screen(u32),
    /// What needs attention: antivirus, updates, restart (ADR-024, stage 4).
    Attention,
    /// A command or script (ADR-024, stage 7); Err: why it cannot run.
    Run(Result<run_rules::Request, &'static str>),
    /// Installed programs (ADR-024, stage 5).
    Programs,
    /// Remove a program by its id from the list.
    Uninstall(String),
    /// Drives, their health, serial number (ADR-024, stage 5).
    Hardware,
    /// The program's log of this computer as an archive.
    Logs,
}

impl Request {
    /// The bar is for every session; the rest only for whoever may control.
    pub fn needs_control(&self) -> bool {
        match self {
            Request::Core(r) => r.needs_control(),
            Request::Autostart(_) | Request::EventLog(_) | Request::Screen(_) | Request::Attention | Request::Run(_)
            | Request::Programs
            | Request::Uninstall(_)
            | Request::Hardware
            | Request::Logs => true,
        }
    }

    /// Long: answered later, so the connection keeps working meanwhile.
    pub fn is_long(&self) -> bool {
        matches!(self, Request::Run(_) | Request::Uninstall(_))
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
    let value = serde_json::from_str::<serde_json::Value>(request).unwrap_or_default();
    match value["op"].as_str().unwrap_or("") {
        op if op.starts_with("autostart") => Request::Autostart(autostart_rules::parse_request(&value)),
        "eventlog" => Request::EventLog(eventlog_rules::parse_request(&value)),
        "screen" => Request::Screen(screen_rules::parse_width(&value)),
        "attention" => Request::Attention,
        "run" => Request::Run(run_rules::parse_request(&value)),
        "programs" => Request::Programs,
        "hardware" => Request::Hardware,
        "uninstall" => Request::Uninstall(value["id"].as_str().unwrap_or("").to_owned()),
        "logs" => Request::Logs,
        _ => Request::Core(rules::parse_request(request)),
    }
}

fn logs() -> (String, Option<(&'static str, String)>) {
    use hbb_common::base64::{engine::general_purpose::STANDARD, Engine};
    match crate::funti_logs::archive() {
        Ok(zip) => (
            serde_json::json!({"op": "logs", "zip": STANDARD.encode(&zip), "size": zip.len()}).to_string(),
            Some(("logs", String::new())),
        ),
        Err(e) => {
            log::info!("FuntiDesk logs: {}", e);
            (rules::error_json("logs", "funti-logs-failed").to_string(), None)
        }
    }
}

fn handle_eventlog(request: &Option<eventlog_rules::Request>) -> String {
    match request {
        None => rules::error_json("eventlog", "funti-admin-bad-request").to_string(),
        #[cfg(windows)]
        Some(r) => eventlog::read(r),
        #[cfg(not(windows))]
        Some(_) => rules::error_json("eventlog", "funti-admin-windows-only").to_string(),
    }
}

/// The picture, unless the owner of this computer turned pictures off.
fn handle_screen(width: u32) -> (String, Option<(&'static str, String)>) {
    let option = hbb_common::config::Config::get_option(screen_rules::OPTION_DISABLE);
    if !screen_rules::allowed(&option) {
        return (rules::error_json("screen", "funti-admin-screen-off").to_string(), None);
    }
    #[cfg(windows)]
    match screen::picture(width) {
        Ok(answer) => (answer, Some(("screen", String::new()))),
        Err(error) => (rules::error_json("screen", error).to_string(), None),
    }
    #[cfg(not(windows))]
    {
        let _ = width;
        (rules::error_json("screen", "funti-admin-windows-only").to_string(), None)
    }
}

fn handle_run(request: &Result<run_rules::Request, &'static str>) -> (String, Option<(&'static str, String)>) {
    let r = match request {
        Ok(r) => r,
        Err(error) => return (rules::error_json("run", error).to_string(), None),
    };
    #[cfg(windows)]
    {
        let (answer, target) = run::run(r);
        (answer, Some(("run", target)))
    }
    #[cfg(not(windows))]
    {
        let mut answer = rules::error_json("run", "funti-admin-windows-only");
        answer["id"] = r.id.clone().into();
        (answer.to_string(), None)
    }
}

fn handle_programs(request: &Request) -> (String, Option<(&'static str, String)>) {
    #[cfg(windows)]
    match request {
        Request::Uninstall(id) => match programs::uninstall(id) {
            Ok(name) => (
                serde_json::json!({"op": "uninstall", "id": id, "name": name}).to_string(),
                Some(("uninstall", name)),
            ),
            Err(error) => {
                let mut answer = rules::error_json("uninstall", error);
                answer["id"] = id.clone().into();
                (answer.to_string(), None)
            }
        },
        _ => (programs::list(), None),
    }
    #[cfg(not(windows))]
    {
        let op = if matches!(request, Request::Uninstall(_)) { "uninstall" } else { "programs" };
        (rules::error_json(op, "funti-admin-windows-only").to_string(), None)
    }
}

fn hardware_answer() -> String {
    #[cfg(windows)]
    return storage::hardware();
    #[cfg(not(windows))]
    storage_rules::answer_json("", &[]).to_string()
}

fn attention() -> String {
    let mut facts = attention_rules::Facts::default();
    facts.uptime_days = SYSTEM.lock().unwrap().uptime() / 86400;
    let wanted = system_disk();
    facts.disk_percent = Disks::new_with_refreshed_list()
        .list()
        .iter()
        .find(|d| d.mount_point().to_string_lossy().eq_ignore_ascii_case(&wanted))
        .filter(|d| d.total_space() > 0)
        .map(|d| (100 * d.total_space().saturating_sub(d.available_space()) / d.total_space()) as u8)
        .unwrap_or(0);
    #[cfg(windows)]
    attention::facts(&mut facts);
    attention_rules::answer_json(&facts).to_string()
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
        Request::EventLog(e) => return (handle_eventlog(e), None),
        Request::Screen(width) => return handle_screen(*width),
        Request::Attention => return (attention(), None),
        Request::Run(r) => return handle_run(r),
        Request::Programs | Request::Uninstall(_) => return handle_programs(request),
        Request::Hardware => return (hardware_answer(), None),
        Request::Logs => return logs(),
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
