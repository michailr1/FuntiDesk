//! FUNTIDESK: one-time separation from a RustDesk installed on the same machine.
//!
//! Earlier builds copied the RustDesk profile on first start, and both products
//! derived the ID from the same MAC address. Where a RustDesk profile is found,
//! FuntiDesk drops what still matches it: an equal ID gets a new one, and saved
//! peers, favorites and the address book / group cache that RustDesk has too are
//! removed. The RustDesk profile is only read, never changed. Each check runs once,
//! when it first finds a RustDesk profile to compare against.

use hbb_common::{
    config::{self, Config, LocalConfig},
    log,
    password_security::decrypt_str_or_original,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, fs, path::PathBuf};

const RUSTDESK: &str = "RustDesk";
const OPTION_ID_DONE: &str = "funti-rustdesk-id-separated";
const OPTION_PEERS_DONE: &str = "funti-rustdesk-peers-separated";

#[derive(Debug, Default, Serialize, Deserialize)]
struct ForeignId {
    #[serde(default)]
    id: String,
    #[serde(default)]
    enc_id: String,
}

/// Called by the process that registers the ID, before it registers.
pub fn separate_id_once() {
    if LocalConfig::get_option(OPTION_ID_DONE) == "Y" {
        return;
    }
    let file = Config::path_for_app(RUSTDESK, format!("{RUSTDESK}.toml"));
    if !file.is_file() {
        return;
    }
    let foreign: ForeignId = config::load_path(file);
    let foreign_id = if foreign.enc_id.is_empty() {
        foreign.id
    } else {
        // The version only decides whether a re-store is due; nothing is stored here.
        decrypt_str_or_original(&foreign.enc_id, "00").0
    };
    let id = Config::get_id();
    if !foreign_id.is_empty() && foreign_id == id {
        Config::set_key_confirmed(false);
        while Config::get_id() == foreign_id {
            Config::update_id();
        }
        log::info!(
            "FuntiDesk: ID {} was the RustDesk ID, new ID {}",
            id,
            Config::get_id()
        );
    }
    LocalConfig::set_option(OPTION_ID_DONE.to_owned(), "Y".to_owned());
}

/// Called in the user's processes: peers and favorites are per user.
pub fn separate_peers_once() {
    if LocalConfig::get_option(OPTION_PEERS_DONE) == "Y" {
        return;
    }
    let foreign_dir = Config::path_for_app(RUSTDESK, "peers");
    let Ok(entries) = fs::read_dir(&foreign_dir) else {
        return;
    };
    let foreign: HashSet<_> = entries.flatten().map(|e| e.file_name()).collect();
    let mut removed = 0;
    if let Ok(entries) = fs::read_dir(Config::path("peers")) {
        for entry in entries.flatten() {
            if foreign.contains(&entry.file_name()) && fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
    }
    let foreign_ids: HashSet<String> = foreign
        .iter()
        .filter_map(|name| name.to_str()?.strip_suffix(".toml").map(str::to_owned))
        .collect();
    let fav = LocalConfig::get_fav();
    let kept: Vec<String> = fav
        .iter()
        .filter(|id| !foreign_ids.contains(*id))
        .cloned()
        .collect();
    if kept.len() != fav.len() {
        LocalConfig::set_fav(kept);
    }
    let app = config::APP_NAME.read().unwrap().clone();
    for suffix in ["_ab", "_group"] {
        remove_if_same(
            Config::path(format!("{app}{suffix}")),
            Config::path_for_app(RUSTDESK, format!("{RUSTDESK}{suffix}")),
        );
    }
    log::info!("FuntiDesk: removed {removed} saved peers that RustDesk has too");
    LocalConfig::set_option(OPTION_PEERS_DONE.to_owned(), "Y".to_owned());
}

fn remove_if_same(own: PathBuf, foreign: PathBuf) {
    if let (Ok(a), Ok(b)) = (fs::read(&own), fs::read(&foreign)) {
        if a == b && fs::remove_file(&own).is_ok() {
            log::info!("FuntiDesk: removed {} copied from RustDesk", own.display());
        }
    }
}
