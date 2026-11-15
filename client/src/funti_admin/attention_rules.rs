//! FUNTIDESK (ADR-024, stage 4; ADR-023, stage 3): what on a computer needs
//! attention — antivirus off or out of date, updates not installed for long,
//! a restart pending, long without a restart, the system disk full. Only std
//! and serde_json here, so this file is also built and tested on its own.

use serde_json::{json, Value};

/// Thresholds; the window shows the reason, not just a red mark.
pub const UPDATES_DAYS: u64 = 45;
pub const UPTIME_DAYS: u64 = 30;
pub const SIGNATURES_DAYS: u64 = 7;
pub const DISK_PERCENT: u8 = 90;

#[derive(Debug, Default, PartialEq)]
pub struct Antivirus {
    pub name: String,
    pub enabled: bool,
    pub up_to_date: bool,
}

#[derive(Debug, Default, PartialEq)]
pub struct Defender {
    pub enabled: bool,
    pub realtime: bool,
    pub signature_days: u64,
}

#[derive(Debug, Default)]
pub struct Facts {
    pub restart_pending: bool,
    pub uptime_days: u64,
    pub disk_percent: u8,
    /// From Windows Security Center; None where it does not exist (Windows
    /// Server) or could not be read.
    pub antivirus: Option<Vec<Antivirus>>,
    pub defender: Option<Defender>,
    /// Days since Windows Update last installed something.
    pub update_days: Option<u64>,
}

/// `productState` of Security Center: the "enabled" nibble at bits 12–15,
/// the "out of date" nibble at bits 4–7.
pub fn antivirus_state(name: &str, state: u64) -> Antivirus {
    Antivirus {
        name: name.to_owned(),
        enabled: (state >> 12) & 0xF == 1,
        up_to_date: (state >> 4) & 0xF == 0,
    }
}

/// What the PowerShell part found (see `attention.rs`): `av`, `defender`,
/// `update` (ISO time of the last installation).
pub fn parse_powershell(v: &Value, now_unix: i64, facts: &mut Facts) {
    if let Some(list) = v["av"].as_array() {
        facts.antivirus = Some(
            list.iter()
                .map(|a| antivirus_state(a["name"].as_str().unwrap_or(""), a["state"].as_u64().unwrap_or(0)))
                .collect(),
        );
    } else if let Some(a) = v["av"].as_object() {
        // A single product comes as an object, not a list.
        facts.antivirus = Some(vec![antivirus_state(
            a.get("name").and_then(Value::as_str).unwrap_or(""),
            a.get("state").and_then(Value::as_u64).unwrap_or(0),
        )]);
    }
    let d = &v["defender"];
    if d.is_object() {
        facts.defender = Some(Defender {
            enabled: d["av"].as_bool().unwrap_or(false),
            realtime: d["rt"].as_bool().unwrap_or(false),
            signature_days: d["age"].as_u64().unwrap_or(0),
        });
    }
    if let Some(t) = v["update"].as_i64() {
        if t > 0 && now_unix >= t {
            facts.update_days = Some(((now_unix - t) / 86400) as u64);
        }
    }
}

/// The items: kind (translation key "funti-attention-<kind>"), "error" or
/// "warning", and a detail for "{}".
pub fn items(f: &Facts) -> Vec<(&'static str, &'static str, String)> {
    let mut out = Vec::new();
    match &f.antivirus {
        Some(list) => {
            let on: Vec<&Antivirus> = list.iter().filter(|a| a.enabled).collect();
            if on.is_empty() {
                let names: Vec<&str> = list.iter().map(|a| a.name.as_str()).collect();
                out.push(("antivirus-off", "error", names.join(", ")));
            } else {
                for a in on.iter().filter(|a| !a.up_to_date) {
                    out.push(("antivirus-old", "warning", a.name.clone()));
                }
            }
        }
        // No Security Center: Defender is all we know.
        None => match &f.defender {
            Some(d) if !d.enabled || !d.realtime => {
                out.push(("antivirus-off", "error", "Microsoft Defender".to_owned()))
            }
            Some(d) if d.signature_days > SIGNATURES_DAYS => {
                out.push(("antivirus-old", "warning", "Microsoft Defender".to_owned()))
            }
            _ => {}
        },
    }
    if let Some(days) = f.update_days {
        if days > UPDATES_DAYS {
            out.push(("updates", "warning", days.to_string()));
        }
    }
    if f.restart_pending {
        out.push(("restart", "warning", String::new()));
    }
    if f.uptime_days > UPTIME_DAYS {
        out.push(("uptime", "warning", f.uptime_days.to_string()));
    }
    if f.disk_percent >= DISK_PERCENT {
        out.push(("disk", "error", f.disk_percent.to_string()));
    }
    out
}

pub fn answer_json(f: &Facts) -> Value {
    json!({
        "op": "attention",
        "items": items(f).into_iter().map(|(kind, level, detail)| json!({
            "kind": kind, "level": level, "detail": detail,
        })).collect::<Vec<_>>(),
        "antivirus": f.antivirus.as_ref().map(|l| l.iter().map(|a| json!({
            "name": a.name, "enabled": a.enabled, "upToDate": a.up_to_date,
        })).collect::<Vec<_>>()),
        "updateDays": f.update_days,
        "restartPending": f.restart_pending,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(f: &Facts) -> Vec<&'static str> {
        items(f).into_iter().map(|i| i.0).collect()
    }

    #[test]
    fn product_state() {
        // Defender on and up to date, off, on and out of date.
        assert_eq!(antivirus_state("D", 397568), Antivirus { name: "D".into(), enabled: true, up_to_date: true });
        assert!(!antivirus_state("D", 393472).enabled);
        assert!(!antivirus_state("D", 397584).up_to_date);
    }

    #[test]
    fn all_well() {
        let f = Facts {
            antivirus: Some(vec![antivirus_state("Microsoft Defender", 397568)]),
            update_days: Some(3),
            uptime_days: 2,
            disk_percent: 40,
            ..Default::default()
        };
        assert!(items(&f).is_empty());
    }

    #[test]
    fn problems() {
        let f = Facts {
            antivirus: Some(vec![antivirus_state("Microsoft Defender", 393472), antivirus_state("Other", 262144)]),
            update_days: Some(60),
            restart_pending: true,
            uptime_days: 40,
            disk_percent: 95,
            ..Default::default()
        };
        assert_eq!(kinds(&f), ["antivirus-off", "updates", "restart", "uptime", "disk"]);
        assert_eq!(items(&f)[0].2, "Microsoft Defender, Other");
    }

    #[test]
    fn third_party_on_defender_passive() {
        let f = Facts {
            antivirus: Some(vec![antivirus_state("Microsoft Defender", 393472), antivirus_state("Kaspersky", 266240)]),
            defender: Some(Defender { enabled: false, realtime: false, signature_days: 30 }),
            ..Default::default()
        };
        assert!(kinds(&f).is_empty());
    }

    #[test]
    fn server_has_only_defender() {
        let mut f = Facts { defender: Some(Defender { enabled: true, realtime: false, signature_days: 1 }), ..Default::default() };
        assert_eq!(kinds(&f), ["antivirus-off"]);
        f.defender = Some(Defender { enabled: true, realtime: true, signature_days: 10 });
        assert_eq!(kinds(&f), ["antivirus-old"]);
        f.defender = None;
        assert!(kinds(&f).is_empty());
    }

    #[test]
    fn powershell_output() {
        let mut f = Facts::default();
        let v = json!({"av": {"name": "Windows Defender", "state": 397568},
            "defender": {"av": true, "rt": true, "age": 1}, "update": 1_000_000});
        parse_powershell(&v, 1_000_000 + 50 * 86400, &mut f);
        assert_eq!(f.antivirus.as_ref().unwrap().len(), 1);
        assert_eq!(f.update_days, Some(50));
        assert_eq!(f.defender.as_ref().unwrap().signature_days, 1);
        let mut g = Facts::default();
        parse_powershell(&json!({"av": [{"name": "A", "state": 397568}, {"name": "B", "state": 0}]}), 0, &mut g);
        assert_eq!(g.antivirus.unwrap().len(), 2);
        let mut h = Facts::default();
        parse_powershell(&json!("garbage"), 0, &mut h);
        assert!(h.antivirus.is_none() && h.defender.is_none() && h.update_days.is_none());
    }
}
