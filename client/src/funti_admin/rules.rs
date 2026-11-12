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
    Bad,
}

impl Request {
    /// The bar is for every session; the rest only for whoever may control.
    pub fn needs_control(&self) -> bool {
        !matches!(self, Request::Status)
    }

    pub fn op(&self) -> &'static str {
        match self {
            Request::Status => "status",
            Request::Processes => "processes",
            Request::Kill(_) => "kill",
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
    fn status() {
        let v = status_json(41.6, 6, 16, 80, 100, "C:\\");
        assert_eq!(v["cpu"], 42);
        assert_eq!(v["mem_used"], 6);
        assert_eq!(v["disk"], "C:\\");
        assert_eq!(status_json(-3.0, 0, 0, 0, 0, "")["cpu"], 0);
        assert_eq!(error_json("kill", "funti-admin-protected")["error"], "funti-admin-protected");
    }
}
