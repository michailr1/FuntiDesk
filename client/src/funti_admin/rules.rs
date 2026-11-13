//! FUNTIDESK (ADR-023): requests of the administration layer and what may
//! not be touched. Only std and serde_json here, so this file is also built
//! and tested on its own (scripts/ci/test-funti-rust.sh).

use serde_json::{json, Value};

/// Processes sent to the other side at most.
pub const PROCESSES_MAX: usize = 400;
const NAME_MAX: usize = 80;

pub enum Request {
    /// Processor, memory and system disk for the bar.
    Status,
    Processes,
    Kill(u32),
    /// Windows services (stage 2).
    Services,
    /// ADR-024: what the computer is (system, hardware, virtual or not).
    Info,
    /// ADR-024: this computer's connection journal (ADR-020).
    Journal,
    Service(String, ServiceAction),
    Bad,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ServiceAction {
    Start,
    Stop,
    Restart,
}

impl ServiceAction {
    pub fn name(self) -> &'static str {
        match self {
            ServiceAction::Start => "start",
            ServiceAction::Stop => "stop",
            ServiceAction::Restart => "restart",
        }
    }
}

impl Request {
    /// The bar is for every session; the rest only for whoever may control.
    #[allow(dead_code)]
    pub fn needs_control(&self) -> bool {
        !matches!(self, Request::Status)
    }

    pub fn op(&self) -> &'static str {
        match self {
            Request::Status => "status",
            Request::Processes => "processes",
            Request::Kill(_) => "kill",
            Request::Services => "services",
            Request::Info => "info",
            Request::Journal => "journal",
            Request::Service(..) => "service",
            Request::Bad => "",
        }
    }
}

pub fn parse_request(text: &str) -> Request {
    let Ok(v) = serde_json::from_str::<Value>(text) else {
        return Request::Bad;
    };
    match v["op"].as_str() {
        Some("status") => Request::Status,
        Some("processes") => Request::Processes,
        Some("kill") => match v["pid"].as_u64().and_then(|p| u32::try_from(p).ok()) {
            Some(pid) => Request::Kill(pid),
            None => Request::Bad,
        },
        Some("services") => Request::Services,
        Some("info") => Request::Info,
        Some("journal") => Request::Journal,
        Some("service") => {
            let action = match v["action"].as_str() {
                Some("start") => ServiceAction::Start,
                Some("stop") => ServiceAction::Stop,
                Some("restart") => ServiceAction::Restart,
                _ => return Request::Bad,
            };
            match v["name"].as_str().filter(|n| service_name_ok(n)) {
                Some(name) => Request::Service(name.to_owned(), action),
                None => Request::Bad,
            }
        }
        _ => Request::Bad,
    }
}

/// Windows does not live without these; ending them ends the session of
/// everyone or the system itself.
const PROTECTED: &[&str] = &[
    "system", "registry", "smss", "csrss", "wininit", "winlogon", "services", "lsass",
    "svchost", "fontdrvhost", "dwm", "memory compression", "secure system",
    // Linux and macOS
    "systemd", "init", "launchd", "kernel_task",
];

/// A process that is never ended from a session: the system's own, this
/// FuntiDesk (any of its processes), and the lowest process numbers.
pub fn protected(pid: u32, name: &str, own_name: &str) -> bool {
    let plain = |n: &str| {
        let n = n.trim().to_lowercase();
        n.strip_suffix(".exe").map(str::to_owned).unwrap_or(n)
    };
    let name = plain(name);
    pid <= 4 || name.is_empty() || name == plain(own_name) || PROTECTED.contains(&name.as_str())
}

/// A service name as Windows keeps it: a registry key name, no path parts.
pub fn service_name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 256
        && name.chars().all(|c| c.is_ascii_graphic() && c != '\\' && c != '/')
}

/// Windows does not work without these, or they keep it safe; FuntiDesk's
/// own service keeps the session itself. They are only shown.
const PROTECTED_SERVICES: &[&str] = &[
    "rpcss", "rpceptmapper", "dcomlaunch", "lsm", "samss", "winmgmt", "eventlog", "plugplay",
    "power", "bfe", "mpssvc", "windefend", "wscsvc", "securityhealthservice", "cryptsvc",
    "dhcp", "dnscache", "nsi", "profsvc", "schedule", "sens", "systemeventsbroker", "gpsvc",
    "brokerinfrastructure", "coremessagingregistrar", "staterepository", "termservice",
    "umrdpservice", "sessionenv", "audiosrv", "audioendpointbuilder", "lanmanworkstation",
    "netlogon", "keyiso", "vaultsvc", "wdnissvc", "sgrmbroker",
];

pub fn service_protected(name: &str, own_service: &str) -> bool {
    let name = name.to_lowercase();
    name == own_service.to_lowercase() || PROTECTED_SERVICES.contains(&name.as_str())
}

/// "auto", "delayed", "manual", "disabled" or "boot" from the registry
/// value `Start` and `DelayedAutostart`.
pub fn start_type(start: u32, delayed: bool) -> &'static str {
    match start {
        0 | 1 => "boot",
        2 if delayed => "delayed",
        2 => "auto",
        3 => "manual",
        _ => "disabled",
    }
}

pub struct Svc {
    pub name: String,
    pub display: String,
    /// "running", "stopped", "starting", "stopping", "paused" or "".
    pub state: &'static str,
    pub start: &'static str,
}

/// Running ones first, then by the shown name.
pub fn services_json(mut list: Vec<Svc>, own_service: &str) -> Value {
    list.sort_by(|a, b| {
        (b.state == "running")
            .cmp(&(a.state == "running"))
            .then_with(|| a.display.to_lowercase().cmp(&b.display.to_lowercase()))
    });
    json!({
        "op": "services",
        "services": list.iter().map(|s| json!({
            "name": text(&s.name),
            "display": text(if s.display.is_empty() { &s.name } else { &s.display }),
            "state": s.state,
            "start": s.start,
            "protected": service_protected(&s.name, own_service),
        })).collect::<Vec<_>>(),
    })
}

pub struct Proc {
    pub pid: u32,
    pub name: String,
    /// Share of the whole processor, 0..100.
    pub cpu: f32,
    pub memory: u64,
    pub user: String,
}

fn text(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(NAME_MAX).collect()
}

/// The heaviest processes first (by processor, then memory); cut to
/// PROCESSES_MAX. `total` tells how many there were.
pub fn processes_json(mut list: Vec<Proc>, own_name: &str) -> Value {
    let total = list.len();
    list.sort_by(|a, b| {
        b.cpu
            .partial_cmp(&a.cpu)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.memory.cmp(&a.memory))
    });
    list.truncate(PROCESSES_MAX);
    json!({
        "op": "processes",
        "total": total,
        "processes": list.iter().map(|p| json!({
            "pid": p.pid,
            "name": text(&p.name),
            "cpu": ((p.cpu as f64).clamp(0.0, 100.0) * 10.0).round() / 10.0,
            "mem": p.memory,
            "user": text(&p.user),
            "protected": protected(p.pid, &p.name, own_name),
        })).collect::<Vec<_>>(),
    })
}

pub fn status_json(cpu: f32, mem_used: u64, mem_total: u64, disk_used: u64, disk_total: u64, disk: &str) -> Value {
    json!({
        "op": "status",
        "cpu": cpu.clamp(0.0, 100.0).round() as u32,
        "mem_used": mem_used,
        "mem_total": mem_total,
        "disk_used": disk_used,
        "disk_total": disk_total,
        "disk": text(disk),
    })
}

/// The virtualization platform when the firmware says the computer is a
/// virtual machine: by the system maker and model as Windows (SMBIOS) or
/// Linux (/sys/class/dmi) report them.
pub fn virtual_machine(maker: &str, model: &str) -> Option<&'static str> {
    let both = format!("{} {}", maker, model).to_lowercase();
    let known: &[(&str, &str)] = &[
        ("vmware", "VMware"),
        ("virtualbox", "VirtualBox"),
        ("innotek", "VirtualBox"),
        ("qemu", "QEMU/KVM"),
        ("kvm", "QEMU/KVM"),
        ("xen", "Xen"),
        ("parallels", "Parallels"),
        ("bochs", "QEMU/KVM"),
        ("proxmox", "Proxmox"),
        ("amazon ec2", "Amazon EC2"),
        ("google compute engine", "Google Cloud"),
    ];
    if both.contains("microsoft") && both.contains("virtual machine") {
        return Some("Hyper-V");
    }
    known.iter().find(|(needle, _)| both.contains(needle)).map(|(_, name)| *name)
}

#[derive(Default)]
pub struct HostInfo {
    pub os: String,
    pub hostname: String,
    pub user: String,
    pub uptime: u64,
    pub maker: String,
    pub model: String,
    pub board: String,
    pub cpu: String,
    pub cores: usize,
    pub threads: usize,
    pub memory: u64,
    pub gpus: Vec<String>,
    /// (name or mount point, size in bytes, "SSD"/"HDD"/"")
    pub disks: Vec<(String, u64, String)>,
}

fn clean(s: &str) -> String {
    let s = text(s.trim());
    // Firmware placeholders say nothing.
    match s.to_lowercase().as_str() {
        "" | "to be filled by o.e.m." | "default string" | "system product name" | "system manufacturer"
        | "not applicable" | "none" | "0" => String::new(),
        _ => s,
    }
}

pub fn info_json(i: &HostInfo) -> Value {
    let maker = clean(&i.maker);
    let model = clean(&i.model);
    let vm = virtual_machine(&maker, &model);
    let mut gpus: Vec<String> = i.gpus.iter().map(|g| clean(g)).filter(|g| !g.is_empty()).collect();
    gpus.dedup();
    json!({
        "op": "info",
        "os": text(&i.os),
        "hostname": text(&i.hostname),
        "user": text(&i.user),
        "uptime": i.uptime,
        "maker": maker,
        "model": model,
        "board": clean(&i.board),
        "vm": vm.unwrap_or_default(),
        "cpu": clean(&i.cpu),
        "cores": i.cores,
        "threads": i.threads,
        "memory": i.memory,
        "gpus": gpus,
        "disks": i.disks.iter().take(16).map(|(n, size, kind)| json!({"name": text(n), "size": size, "kind": kind})).collect::<Vec<_>>(),
    })
}

pub fn error_json(op: &str, error: &str) -> Value {
    json!({"op": op, "error": error})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests() {
        assert!(matches!(parse_request("{\"op\":\"status\"}"), Request::Status));
        assert!(matches!(parse_request("{\"op\":\"processes\"}"), Request::Processes));
        assert!(matches!(parse_request("{\"op\":\"kill\",\"pid\":1234}"), Request::Kill(1234)));
        for bad in ["", "x", "{}", "{\"op\":\"kill\"}", "{\"op\":\"kill\",\"pid\":-1}",
                    "{\"op\":\"kill\",\"pid\":\"12\"}", "{\"op\":\"kill\",\"pid\":99999999999}",
                    "{\"op\":\"format\"}"] {
            assert!(matches!(parse_request(bad), Request::Bad), "{bad}");
        }
        assert!(matches!(parse_request("{\"op\":\"services\"}"), Request::Services));
        assert!(matches!(
            parse_request("{\"op\":\"service\",\"name\":\"Spooler\",\"action\":\"restart\"}"),
            Request::Service(n, ServiceAction::Restart) if n == "Spooler"
        ));
        for bad in ["{\"op\":\"service\",\"name\":\"Spooler\"}",
                    "{\"op\":\"service\",\"name\":\"Spooler\",\"action\":\"delete\"}",
                    "{\"op\":\"service\",\"name\":\"..\\\\x\",\"action\":\"stop\"}",
                    "{\"op\":\"service\",\"name\":\"a b\",\"action\":\"stop\"}",
                    "{\"op\":\"service\",\"name\":\"\",\"action\":\"stop\"}"] {
            assert!(matches!(parse_request(bad), Request::Bad), "{bad}");
        }
        assert!(Request::Services.needs_control());
        assert!(!Request::Status.needs_control());
        assert!(Request::Processes.needs_control() && Request::Kill(1).needs_control());
    }

    #[test]
    fn what_is_never_ended() {
        for (pid, name) in [(0, "System Idle Process"), (4, "System"), (600, "csrss.exe"),
                            (700, "LSASS.EXE"), (800, "winlogon.exe"), (900, "svchost.exe"),
                            (1000, "FuntiDesk.exe"), (1001, "funtidesk"), (1, "systemd"), (1200, "")] {
            assert!(protected(pid, name, "FuntiDesk.exe"), "{pid} {name}");
        }
        for (pid, name) in [(5000, "chrome.exe"), (5001, "notepad.exe"), (5002, "services-helper.exe"),
                            (5003, "system32tool.exe")] {
            assert!(!protected(pid, name, "FuntiDesk.exe"), "{pid} {name}");
        }
    }

    #[test]
    fn the_heaviest_processes_come_first_and_the_list_is_cut() {
        let mut list: Vec<Proc> = (0..500u32)
            .map(|n| Proc { pid: 5000 + n, name: format!("p{n}.exe"), cpu: 0.0, memory: n as u64, user: "u".into() })
            .collect();
        list.push(Proc { pid: 9000, name: "busy\n.exe".into(), cpu: 250.0, memory: 1, user: "Мама".into() });
        list.push(Proc { pid: 700, name: "lsass.exe".into(), cpu: 3.26, memory: 9, user: "SYSTEM".into() });
        let v = processes_json(list, "FuntiDesk.exe");
        assert_eq!(v["total"], 502);
        let rows = v["processes"].as_array().unwrap();
        assert_eq!(rows.len(), PROCESSES_MAX);
        assert_eq!(rows[0]["name"], "busy.exe");
        assert_eq!(rows[0]["cpu"], 100.0);
        assert_eq!(rows[0]["protected"], false);
        assert_eq!(rows[1]["name"], "lsass.exe");
        assert_eq!(rows[1]["cpu"], 3.3);
        assert_eq!(rows[1]["protected"], true);
        assert_eq!(rows[2]["mem"], 499);
    }

    #[test]
    fn services() {
        assert_eq!(start_type(2, false), "auto");
        assert_eq!(start_type(2, true), "delayed");
        assert_eq!(start_type(3, true), "manual");
        assert_eq!(start_type(4, false), "disabled");
        assert_eq!(start_type(1, false), "boot");
        assert!(service_protected("RpcSs", "FuntiDesk"));
        assert!(service_protected("funtidesk", "FuntiDesk"));
        assert!(!service_protected("Spooler", "FuntiDesk"));
        let list = vec![
            Svc { name: "b".into(), display: "Zeta".into(), state: "stopped", start: "manual" },
            Svc { name: "Spooler".into(), display: "Диспетчер печати".into(), state: "running", start: "auto" },
            Svc { name: "WinDefend".into(), display: "".into(), state: "running", start: "auto" },
            Svc { name: "a".into(), display: "alpha".into(), state: "stopped", start: "disabled" },
        ];
        let v = services_json(list, "FuntiDesk");
        let rows = v["services"].as_array().unwrap();
        let names: Vec<_> = rows.iter().map(|r| r["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["WinDefend", "Spooler", "a", "b"]);
        assert_eq!(rows[0]["display"], "WinDefend");
        assert_eq!(rows[0]["protected"], true);
        assert_eq!(rows[1]["protected"], false);
    }

    #[test]
    fn virtual_machines() {
        assert_eq!(virtual_machine("Microsoft Corporation", "Virtual Machine"), Some("Hyper-V"));
        assert_eq!(virtual_machine("VMware, Inc.", "VMware20,1"), Some("VMware"));
        assert_eq!(virtual_machine("innotek GmbH", "VirtualBox"), Some("VirtualBox"));
        assert_eq!(virtual_machine("QEMU", "Standard PC (Q35 + ICH9, 2009)"), Some("QEMU/KVM"));
        assert_eq!(virtual_machine("Xen", "HVM domU"), Some("Xen"));
        assert_eq!(virtual_machine("Microsoft Corporation", "Surface Laptop 5"), None);
        assert_eq!(virtual_machine("LENOVO", "11MY0034RU"), None);
        assert_eq!(virtual_machine("", ""), None);
    }

    #[test]
    fn host_info() {
        let mut i = HostInfo {
            os: "Windows 11 Pro 24H2".into(),
            maker: "Microsoft Corporation".into(),
            model: "Virtual Machine".into(),
            board: "To be filled by O.E.M.".into(),
            cpu: " Intel(R) Xeon(R) E-2336 CPU @ 2.90GHz ".into(),
            cores: 4,
            threads: 4,
            memory: 12 << 30,
            gpus: vec!["Microsoft Hyper-V Video".into(), "Microsoft Hyper-V Video".into(), "".into()],
            disks: vec![("C:\\".into(), 200 << 30, "SSD".into())],
            ..Default::default()
        };
        let v = info_json(&i);
        assert_eq!(v["vm"], "Hyper-V");
        assert_eq!(v["board"], "");
        assert_eq!(v["cpu"], "Intel(R) Xeon(R) E-2336 CPU @ 2.90GHz");
        assert_eq!(v["gpus"].as_array().unwrap().len(), 1);
        assert_eq!(v["disks"][0]["kind"], "SSD");
        i.maker = "ASUS".into();
        i.model = "System Product Name".into();
        let v = info_json(&i);
        assert_eq!(v["vm"], "");
        assert_eq!(v["model"], "");
        assert!(matches!(parse_request("{\"op\":\"info\"}"), Request::Info));
        assert!(matches!(parse_request("{\"op\":\"journal\"}"), Request::Journal));
        assert!(Request::Info.needs_control() && Request::Journal.needs_control());
    }

    #[test]
    fn status() {
        let v = status_json(41.6, 6, 16, 80, 100, "C:\\");
        assert_eq!(v["cpu"], 42);
        assert_eq!(v["mem_used"], 6);
        assert_eq!(v["disk"], "C:\\");
        assert_eq!(status_json(-3.0, 0, 0, 0, 0, "")["cpu"], 0);
        assert_eq!(error_json("kill", "funti-admin-protected")["error"], "funti-admin-protected");
    }
}
