//! FUNTIDESK (ADR-025): every five minutes the service adds a line with the
//! load of this computer to a file it keeps for seven days; the workplace
//! asks for it over the service connection.

use super::history_rules::{self as rules, Sample};
use hbb_common::{config::Config, log};
use std::{io::Write, path::PathBuf, sync::Mutex};

lazy_static::lazy_static! {
    static ref FILE: Mutex<()> = Mutex::new(());
}

fn path() -> PathBuf {
    Config::path("funti_history.jsonl")
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn enabled() -> bool {
    Config::get_option(rules::OPTION_DISABLE) != "Y"
}

fn append(s: &Sample, prune: bool) {
    let _lock = FILE.lock().unwrap();
    let p = path();
    if prune {
        let text = std::fs::read_to_string(&p).unwrap_or_default();
        let kept: String = rules::keep(&text, s.t).iter().map(|x| rules::line(x) + "\n").collect();
        std::fs::write(&p, kept).ok();
    }
    match std::fs::OpenOptions::new().create(true).append(true).open(&p) {
        Ok(mut f) => {
            writeln!(f, "{}", rules::line(s)).ok();
        }
        Err(e) => log::info!("FuntiDesk history: {}", e),
    }
}

/// Starts the sampling thread once per process.
pub fn start() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        std::thread::spawn(|| {
            let mut count: u64 = 0;
            loop {
                if enabled() {
                    let (cpu, memory, disk) = super::load();
                    let s = Sample { t: now(), cpu, memory, disk };
                    // Old lines go once an hour.
                    append(&s, count % 12 == 0);
                    count += 1;
                } else {
                    let _lock = FILE.lock().unwrap();
                    std::fs::remove_file(path()).ok();
                }
                std::thread::sleep(std::time::Duration::from_secs(rules::STEP_SECONDS as u64));
            }
        });
    });
}

pub fn answer(days: i64, uptime: u64) -> String {
    if !enabled() {
        return super::rules::error_json("history", "funti-history-off-host").to_string();
    }
    let text = {
        let _lock = FILE.lock().unwrap();
        std::fs::read_to_string(path()).unwrap_or_default()
    };
    let now = now();
    rules::answer_json(&rules::keep(&text, now), now, days, now - uptime as i64).to_string()
}
