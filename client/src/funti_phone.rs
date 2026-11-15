//! FUNTIDESK (ADR-026, stage 3): an Android phone answers the workplace —
//! the load bar (memory, storage), what the phone is (model, Android
//! version, battery) and its connection journal. Anything else gets
//! "not on a phone": Android does not let an app see other apps'
//! processes, services or run commands for someone else.

mod parse;
#[path = "funti_admin/rules.rs"]
mod rules;

use serde_json::{json, Value};
use std::process::Command;

fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

fn output(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

fn storage() -> (u64, u64) {
    parse::df(&output("df", &["-k", "/data"])).unwrap_or((0, 0))
}

fn status() -> Value {
    let (total, available) = parse::meminfo(&read("/proc/meminfo")).unwrap_or((0, 0));
    let (disk_total, disk_used) = storage();
    rules::status_json(0.0, total - available, total, disk_used, disk_total, "/data")
}

fn info() -> Value {
    let props = output("getprop", &[]);
    let p = |name: &str| parse::getprop(&props, name).to_owned();
    let (memory, _) = parse::meminfo(&read("/proc/meminfo")).unwrap_or((0, 0));
    let (disk_total, _) = storage();
    let threads = std::thread::available_parallelism().map_or(0, |n| n.get());
    let soc = [p("ro.soc.model"), p("ro.hardware.chipname"), p("ro.board.platform")]
        .into_iter()
        .find(|s| !s.is_empty())
        .unwrap_or_default();
    let mut v = rules::info_json(&rules::HostInfo {
        os: format!("Android {}", p("ro.build.version.release")),
        hostname: p("ro.product.model"),
        user: String::new(),
        uptime: parse::uptime(&read("/proc/uptime")),
        maker: p("ro.product.manufacturer"),
        model: p("ro.product.model"),
        board: String::new(),
        cpu: soc,
        cores: threads,
        threads,
        memory,
        gpus: Vec::new(),
        disks: vec![("/data".to_owned(), disk_total, String::new())],
    });
    if let Some((level, charging)) = parse::battery(
        &read("/sys/class/power_supply/battery/capacity"),
        &read("/sys/class/power_supply/battery/status"),
    ) {
        v["battery"] = json!(level);
        v["charging"] = json!(charging);
    }
    v["phone"] = json!(true);
    v
}

/// The answer to a workplace request (JSON with "op").
pub fn handle(request: &str) -> String {
    let op = serde_json::from_str::<Value>(request)
        .ok()
        .and_then(|v| v["op"].as_str().map(str::to_owned))
        .unwrap_or_default();
    match op.as_str() {
        "status" => status(),
        "info" => info(),
        "journal" => {
            let events = serde_json::from_str::<Value>(&crate::funti_journal::read(false)).unwrap_or_default();
            json!({"op": "journal", "events": events})
        }
        _ => rules::error_json(&op, "funti-admin-not-on-phone"),
    }
    .to_string()
}
