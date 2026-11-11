//! FUNTIDESK (ADR-021): from a session, the controlling side asks this
//! computer to wake a device in its local network (Wake-on-LAN): a computer
//! with FuntiDesk it has seen there, or any device by its network card
//! address. The request arrives in `server/connection.rs`
//! (`funti_wake_request`) and only from whoever may control this computer.
//!
//! To know its neighbours, the process that accepts connections repeats
//! upstream's LAN discovery from time to time; upstream keeps the answers
//! in `LanPeers`.

mod devices;

use devices::{Request, Seen};
use hbb_common::{
    allow_err,
    config::{Config, LanPeers},
    log,
};
use serde_json::json;
use std::{net::IpAddr, time::Duration};

/// Devices added by hand, kept on this computer (JSON list of name and mac).
const OPTION_SAVED: &str = "funti-wake-devices";
/// A computer that was off at one round is found at one of the next.
const EVERY: Duration = Duration::from_secs(3 * 3600);
/// The network may not be up yet right after start.
const FIRST: Duration = Duration::from_secs(60);

pub fn start() {
    std::thread::spawn(|| {
        std::thread::sleep(FIRST);
        loop {
            if let Err(err) = crate::lan::discover() {
                log::info!("FuntiDesk wake: discovery: {}", err);
            }
            std::thread::sleep(EVERY);
        }
    });
}

fn seen() -> Vec<Seen> {
    LanPeers::load()
        .peers
        .iter()
        .map(|p| Seen {
            id: p.id.clone(),
            hostname: p.hostname.clone(),
            macs: p.ip_mac.values().cloned().collect(),
        })
        .collect()
}

/// The wake packet for `mac` from every network card of this computer.
fn send(mac: [u8; 6]) {
    log::info!("FuntiDesk wake: {}", devices::format_mac(&mac));
    for interface in default_net::get_interfaces() {
        for ipv4 in &interface.ipv4 {
            allow_err!(wol::send_wol(wol::MacAddr(mac), None, Some(IpAddr::V4(ipv4.addr))));
        }
    }
}

/// Answers a request of the controlling side (see `devices::parse_request`)
/// with JSON: the device list, and `sent` or `error` for a wake request.
pub fn handle(request: &str) -> String {
    let mut answer = json!({});
    let mut saved = Config::get_option(OPTION_SAVED);
    match devices::parse_request(request) {
        Request::List => {}
        Request::WakeId(id) => {
            if devices::known(&seen(), &id) {
                crate::lan::send_wol(id);
                answer["sent"] = json!(true);
            } else {
                answer["error"] = json!("funti-wake-unknown");
            }
        }
        Request::WakeMac(mac, name) => {
            send(mac);
            answer["sent"] = json!(true);
            if !name.is_empty() {
                saved = devices::remember(&saved, &name, &mac);
                Config::set_option(OPTION_SAVED.to_owned(), saved.clone());
            }
        }
        Request::Forget(mac) => {
            saved = devices::forget(&saved, &mac);
            Config::set_option(OPTION_SAVED.to_owned(), saved.clone());
        }
        Request::Bad(error) => answer["error"] = json!(error),
    }
    answer["devices"] = devices::list(&saved, &seen());
    answer.to_string()
}
