//! FUNTIDESK (ADR-024, stage 5): drives and their health (SMART, as Windows
//! Storage reports it) and the serial number of the computer, for the
//! overview and the inventory. Only std and serde_json here, so this file is
//! also built and tested on its own.

use serde_json::{json, Value};

/// Wear above this, or a temperature above that, is worth a look.
pub const WEAR_WARN: u64 = 80;
pub const TEMPERATURE_WARN: u64 = 60;

#[derive(Debug, Default, PartialEq)]
pub struct Drive {
    pub name: String,
    pub media: String,
    pub bus: String,
    pub size: u64,
    /// "Healthy", "Warning", "Unhealthy" or "".
    pub health: String,
    pub temperature: Option<u64>,
    pub wear: Option<u64>,
    pub hours: Option<u64>,
    pub read_errors: Option<u64>,
}

impl Drive {
    /// "error", "warning" or "" for the window.
    pub fn level(&self) -> &'static str {
        match self.health.as_str() {
            "Unhealthy" => return "error",
            "Warning" => return "warning",
            _ => {}
        }
        let worn = self.wear.map_or(false, |w| w >= WEAR_WARN);
        let hot = self.temperature.map_or(false, |t| t >= TEMPERATURE_WARN);
        let errors = self.read_errors.map_or(false, |e| e > 0);
        if worn || hot || errors {
            "warning"
        } else {
            ""
        }
    }
}

fn opt(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| v.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
}

fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_owned(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

/// MediaType and BusType come as numbers from Get-PhysicalDisk.
fn media(v: &Value) -> String {
    match v.as_u64() {
        Some(3) => "HDD".into(),
        Some(4) => "SSD".into(),
        Some(5) => "SCM".into(),
        Some(_) => String::new(),
        None => text(v),
    }
}

fn bus(v: &Value) -> String {
    match v.as_u64() {
        Some(7) => "USB".into(),
        Some(11) => "SATA".into(),
        Some(17) => "NVMe".into(),
        Some(8) => "RAID".into(),
        Some(10) => "SAS".into(),
        Some(_) => String::new(),
        None => text(v),
    }
}

fn health(v: &Value) -> String {
    match v.as_u64() {
        Some(0) => "Healthy".into(),
        Some(1) => "Warning".into(),
        Some(2) => "Unhealthy".into(),
        Some(_) => String::new(),
        None => text(v),
    }
}

/// What the PowerShell part found: `serial` and `disks` (one object or a
/// list).
pub fn parse_powershell(v: &Value) -> (String, Vec<Drive>) {
    let list: Vec<&Value> = match &v["disks"] {
        Value::Array(a) => a.iter().collect(),
        o @ Value::Object(_) => vec![o],
        _ => Vec::new(),
    };
    let drives = list
        .into_iter()
        .map(|d| Drive {
            name: text(&d["name"]),
            media: media(&d["media"]),
            bus: bus(&d["bus"]),
            size: opt(&d["size"]).unwrap_or(0),
            health: health(&d["health"]),
            temperature: opt(&d["temp"]).filter(|t| *t > 0 && *t < 150),
            wear: opt(&d["wear"]).filter(|w| *w <= 100),
            hours: opt(&d["hours"]),
            read_errors: opt(&d["readErrors"]),
        })
        .collect();
    (text(&v["serial"]), drives)
}

pub fn answer_json(serial: &str, drives: &[Drive]) -> Value {
    json!({
        "op": "hardware",
        "serial": serial,
        "drives": drives.iter().map(|d| json!({
            "name": d.name, "media": d.media, "bus": d.bus, "size": d.size,
            "health": d.health, "temperature": d.temperature, "wear": d.wear,
            "hours": d.hours, "readErrors": d.read_errors, "level": d.level(),
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parsing() {
        let v = json!({"serial": " PF3ABC12 ", "disks": [
            {"name": "Samsung SSD 980 1TB", "media": 4, "bus": 17, "size": 1000204886016u64,
             "health": 0, "temp": 41, "wear": 3, "hours": 5120, "readErrors": 0},
            {"name": "WDC WD10EZEX", "media": 3, "bus": 11, "size": 1000204886016u64,
             "health": 1, "temp": null, "wear": null}
        ]});
        let (serial, d) = parse_powershell(&v);
        assert_eq!(serial, "PF3ABC12");
        assert_eq!((d[0].media.as_str(), d[0].bus.as_str(), d[0].health.as_str()), ("SSD", "NVMe", "Healthy"));
        assert_eq!((d[0].temperature, d[0].wear, d[0].hours), (Some(41), Some(3), Some(5120)));
        assert_eq!(d[0].level(), "");
        assert_eq!((d[1].media.as_str(), d[1].temperature, d[1].level()), ("HDD", None, "warning"));
        let (_, one) = parse_powershell(&json!({"disks": {"name": "X", "health": "Unhealthy"}}));
        assert_eq!(one[0].level(), "error");
        assert!(parse_powershell(&json!("garbage")).1.is_empty());
    }

    #[test]
    fn levels() {
        let mut d = Drive { health: "Healthy".into(), wear: Some(85), ..Default::default() };
        assert_eq!(d.level(), "warning");
        d.wear = Some(10);
        d.temperature = Some(65);
        assert_eq!(d.level(), "warning");
        d.temperature = Some(40);
        d.read_errors = Some(2);
        assert_eq!(d.level(), "warning");
        let (_, odd) = parse_powershell(&json!({"disks": [{"temp": 9999, "wear": 250}]}));
        assert_eq!((odd[0].temperature, odd[0].wear), (None, None));
    }

    #[test]
    fn answer() {
        let a = answer_json("S1", &[Drive { name: "D".into(), health: "Warning".into(), ..Default::default() }]);
        assert_eq!((a["serial"].as_str(), a["drives"][0]["level"].as_str()), (Some("S1"), Some("warning")));
    }
}
