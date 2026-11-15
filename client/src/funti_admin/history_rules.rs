//! FUNTIDESK (ADR-025): the history of this computer — a line every five
//! minutes, kept for seven days, and what the workplace gets of it. Only
//! std and serde_json here, so this file is also built and tested on its own.

use serde_json::{json, Value};

pub const STEP_SECONDS: i64 = 300;
pub const KEEP_SECONDS: i64 = 7 * 86400;
/// The owner of the computer turns history off with this option ("Y").
pub const OPTION_DISABLE: &str = "funti-disable-history";

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sample {
    pub t: i64,
    pub cpu: u8,
    pub memory: u8,
    pub disk: u8,
}

pub fn line(s: &Sample) -> String {
    json!([s.t, s.cpu, s.memory, s.disk]).to_string()
}

pub fn parse_line(l: &str) -> Option<Sample> {
    let v: Value = serde_json::from_str(l.trim()).ok()?;
    let a = v.as_array()?;
    let n = |i: usize| a.get(i).and_then(Value::as_i64);
    let pct = |i: usize| n(i).map(|x| x.clamp(0, 100) as u8);
    Some(Sample { t: n(0)?, cpu: pct(1)?, memory: pct(2)?, disk: pct(3)? })
}

/// The lines still to keep at `now`, oldest first.
pub fn keep(text: &str, now: i64) -> Vec<Sample> {
    let mut out: Vec<Sample> = text
        .lines()
        .filter_map(parse_line)
        .filter(|s| s.t > now - KEEP_SECONDS && s.t <= now + STEP_SECONDS)
        .collect();
    out.sort_by_key(|s| s.t);
    out.dedup_by_key(|s| s.t);
    out
}

/// `{"op":"history","days":1}`: 1 or 7.
pub fn parse_days(v: &Value) -> i64 {
    if v["days"].as_i64() == Some(7) {
        7
    } else {
        1
    }
}

pub fn answer_json(samples: &[Sample], now: i64, days: i64, boot: i64) -> Value {
    let from = now - days * 86400;
    json!({
        "op": "history",
        "days": days,
        "now": now,
        "boot": boot,
        "step": STEP_SECONDS,
        "samples": samples
            .iter()
            .filter(|s| s.t >= from)
            .map(|s| json!([s.t, s.cpu, s.memory, s.disk]))
            .collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines() {
        let s = Sample { t: 1000, cpu: 5, memory: 60, disk: 40 };
        assert_eq!(parse_line(&line(&s)), Some(s));
        assert_eq!(parse_line("[1, 250, -3, 50]"), Some(Sample { t: 1, cpu: 100, memory: 0, disk: 50 }));
        assert_eq!(parse_line("garbage"), None);
        assert_eq!(parse_line("[1, 2]"), None);
    }

    #[test]
    fn keeping() {
        let now = 10 * 86400;
        let text = format!(
            "{}\n{}\nbroken\n{}\n{}\n",
            line(&Sample { t: now - 8 * 86400, cpu: 1, memory: 1, disk: 1 }),
            line(&Sample { t: now - 600, cpu: 2, memory: 2, disk: 2 }),
            line(&Sample { t: now - 900, cpu: 3, memory: 3, disk: 3 }),
            line(&Sample { t: now - 600, cpu: 9, memory: 9, disk: 9 }),
        );
        let k = keep(&text, now);
        assert_eq!(k.iter().map(|s| s.t).collect::<Vec<_>>(), [now - 900, now - 600]);
    }

    #[test]
    fn answers() {
        let now = 10 * 86400;
        let samples = [
            Sample { t: now - 2 * 86400, cpu: 1, memory: 1, disk: 1 },
            Sample { t: now - 3600, cpu: 2, memory: 2, disk: 2 },
        ];
        assert_eq!(answer_json(&samples, now, 1, now - 100)["samples"].as_array().unwrap().len(), 1);
        assert_eq!(answer_json(&samples, now, 7, 0)["samples"].as_array().unwrap().len(), 2);
        assert_eq!(parse_days(&json!({"days": 7})), 7);
        assert_eq!(parse_days(&json!({"days": 30})), 1);
    }
}
