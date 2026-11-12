//! FUNTIDESK (ADR-021): the list of devices this computer can wake, and the
//! requests about it. Only std and serde_json here, so this file is also
//! built and tested on its own (scripts/ci/test-funti-rust.sh).

use serde_json::{json, Value};

/// Devices added by hand that are kept.
const SAVED_MAX: usize = 30;
const NAME_MAX: usize = 40;

/// "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff" or "aabbccddeeff".
pub fn parse_mac(text: &str) -> Option<[u8; 6]> {
    let hex: String = text
        .trim()
        .chars()
        .filter(|c| !matches!(c, ':' | '-' | '.' | ' '))
        .collect();
    if hex.len() != 12 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut mac = [0u8; 6];
    for (i, byte) in mac.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    // All zeros and the broadcast address are not a device.
    (mac != [0; 6] && mac != [0xff; 6]).then_some(mac)
}

pub fn format_mac(mac: &[u8; 6]) -> String {
    mac.iter().map(|b| format!("{b:02X}")).collect::<Vec<_>>().join(":")
}

fn name(text: &str) -> String {
    text.trim().chars().filter(|c| !c.is_control()).take(NAME_MAX).collect()
}

/// A computer with FuntiDesk seen in this local network.
pub struct Seen {
    pub id: String,
    pub hostname: String,
    pub macs: Vec<String>,
}

/// What the other side asks: nothing (just the list), wake a seen computer
/// by its ID, wake a network card address (and keep it under a name), or
/// forget a kept one.
pub enum Request {
    List,
    WakeId(String),
    WakeMac([u8; 6], String),
    Forget([u8; 6]),
    Bad(&'static str),
}

pub fn parse_request(text: &str) -> Request {
    if text.trim().is_empty() {
        return Request::List;
    }
    let Ok(v) = serde_json::from_str::<Value>(text) else {
        return Request::Bad("funti-wake-bad-request");
    };
    if let Some(mac) = v["forget"].as_str() {
        return parse_mac(mac).map(Request::Forget).unwrap_or(Request::Bad("funti-wake-bad-mac"));
    }
    if let Some(id) = v["id"].as_str().filter(|s| !s.is_empty()) {
        return Request::WakeId(id.chars().take(NAME_MAX).collect());
    }
    match v["mac"].as_str() {
        Some(mac) => parse_mac(mac)
            .map(|m| Request::WakeMac(m, name(v["name"].as_str().unwrap_or_default())))
            .unwrap_or(Request::Bad("funti-wake-bad-mac")),
        None => Request::Bad("funti-wake-bad-request"),
    }
}

fn saved_list(saved: &str) -> Vec<(String, [u8; 6])> {
    serde_json::from_str::<Value>(saved)
        .ok()
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|d| Some((name(d["name"].as_str()?), parse_mac(d["mac"].as_str()?)?)))
        .collect()
}

fn saved_json(list: &[(String, [u8; 6])]) -> String {
    Value::Array(
        list.iter()
            .map(|(name, mac)| json!({"name": name, "mac": format_mac(mac)}))
            .collect(),
    )
    .to_string()
}

/// Keeps `mac` under `name` (newest first; the same address is kept once).
pub fn remember(saved: &str, device_name: &str, mac: &[u8; 6]) -> String {
    let mut list = saved_list(saved);
    list.retain(|(_, m)| m != mac);
    list.insert(0, (name(device_name), *mac));
    list.truncate(SAVED_MAX);
    saved_json(&list)
}

pub fn forget(saved: &str, mac: &[u8; 6]) -> String {
    let mut list = saved_list(saved);
    list.retain(|(_, m)| m != mac);
    saved_json(&list)
}

/// The devices for the other side: kept ones first, then the computers with
/// FuntiDesk seen in the network (one row per network card address).
pub fn list(saved: &str, seen: &[Seen]) -> Value {
    let mut rows = Vec::new();
    let mut taken = Vec::new();
    for (device_name, mac) in saved_list(saved) {
        taken.push(mac);
        rows.push(json!({"name": device_name, "mac": format_mac(&mac), "saved": true}));
    }
    for computer in seen {
        for mac in computer.macs.iter().filter_map(|m| parse_mac(m)) {
            if taken.contains(&mac) {
                continue;
            }
            taken.push(mac);
            rows.push(json!({
                "id": name(&computer.id),
                "name": name(&computer.hostname),
                "mac": format_mac(&mac),
                "saved": false,
            }));
        }
    }
    Value::Array(rows)
}

/// Whether a seen computer `id` has an address to wake.
pub fn known(seen: &[Seen], id: &str) -> bool {
    seen.iter().any(|c| c.id == id && c.macs.iter().any(|m| parse_mac(m).is_some()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_card_addresses_in_the_usual_spellings() {
        let want = Some([0xaa, 0xbb, 0x0c, 0x1d, 0x2e, 0xff]);
        assert_eq!(parse_mac("AA:BB:0C:1D:2E:FF"), want);
        assert_eq!(parse_mac(" aa-bb-0c-1d-2e-ff "), want);
        assert_eq!(parse_mac("aabb.0c1d.2eff"), want);
        assert_eq!(parse_mac("AABB0C1D2EFF"), want);
        assert_eq!(format_mac(&want.unwrap()), "AA:BB:0C:1D:2E:FF");
        for bad in ["", "AA:BB:0C:1D:2E", "AA:BB:0C:1D:2E:FF:00", "GG:BB:0C:1D:2E:FF",
                    "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "ааbb0c1d2eff"] {
            assert_eq!(parse_mac(bad), None, "{bad}");
        }
    }

    #[test]
    fn requests() {
        assert!(matches!(parse_request(""), Request::List));
        assert!(matches!(parse_request("{\"id\":\"123456789\"}"), Request::WakeId(id) if id == "123456789"));
        assert!(matches!(
            parse_request("{\"mac\":\"aa-bb-0c-1d-2e-ff\",\"name\":\" NAS\\n \"}"),
            Request::WakeMac(m, n) if m[0] == 0xaa && n == "NAS"
        ));
        assert!(matches!(parse_request("{\"mac\":\"AA:BB:0C:1D:2E:FF\"}"), Request::WakeMac(_, n) if n.is_empty()));
        assert!(matches!(parse_request("{\"forget\":\"AA:BB:0C:1D:2E:FF\"}"), Request::Forget(_)));
        assert!(matches!(parse_request("{\"mac\":\"nope\"}"), Request::Bad("funti-wake-bad-mac")));
        assert!(matches!(parse_request("{\"forget\":\"\"}"), Request::Bad("funti-wake-bad-mac")));
        assert!(matches!(parse_request("{}"), Request::Bad("funti-wake-bad-request")));
        assert!(matches!(parse_request("not json"), Request::Bad("funti-wake-bad-request")));
    }

    #[test]
    fn kept_devices() {
        let a = [1, 2, 3, 4, 5, 6];
        let b = [1, 2, 3, 4, 5, 7];
        let mut saved = remember("", "NAS", &a);
        saved = remember(&saved, "ТВ", &b);
        saved = remember(&saved, &"x".repeat(100), &a);
        let rows = list(&saved, &[]);
        assert_eq!(rows.as_array().unwrap().len(), 2);
        assert_eq!(rows[0]["mac"], "01:02:03:04:05:06");
        assert_eq!(rows[0]["name"].as_str().unwrap().len(), 40);
        assert_eq!(rows[1]["name"], "ТВ");
        saved = forget(&saved, &a);
        assert_eq!(list(&saved, &[]).as_array().unwrap().len(), 1);
        for n in 0..50u8 {
            saved = remember(&saved, "d", &[9, 9, 9, 9, 9, n]);
        }
        assert_eq!(list(&saved, &[]).as_array().unwrap().len(), 30);
        // A broken stored value is an empty list, not an error.
        assert_eq!(list("garbage", &[]).as_array().unwrap().len(), 0);
        assert_eq!(list("[{\"name\":1},{\"mac\":\"zz\",\"name\":\"a\"}]", &[]).as_array().unwrap().len(), 0);
    }

    #[test]
    fn seen_computers_follow_kept_ones_without_repeats() {
        let seen = [
            Seen { id: "111".into(), hostname: "MINIPC".into(), macs: vec!["aa:bb:0c:1d:2e:ff".into(), "".into()] },
            Seen { id: "222".into(), hostname: "LAPTOP".into(), macs: vec!["01:02:03:04:05:06".into()] },
            Seen { id: "333".into(), hostname: "NOMAC".into(), macs: vec![] },
        ];
        let saved = remember("", "Мой ноутбук", &[1, 2, 3, 4, 5, 6]);
        let rows = list(&saved, &seen);
        let rows = rows.as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["saved"], true);
        assert_eq!(rows[1]["id"], "111");
        assert_eq!(rows[1]["name"], "MINIPC");
        assert_eq!(rows[1]["mac"], "AA:BB:0C:1D:2E:FF");
        assert!(known(&seen, "111") && known(&seen, "222"));
        assert!(!known(&seen, "333") && !known(&seen, "444"));
    }
}
