//! FUNTIDESK (ADR-020): a local journal of incoming connections — who got
//! in, for how long, which files moved, and which attempts were refused.
//! It is written next to the settings of the process that accepts
//! connections and is never sent anywhere.
//!
//! The events are the ones upstream prepares for its audit server (which
//! FuntiDesk does not have): `server/connection.rs` calls in here from
//! `post_conn_audit`, `post_file_audit` and `post_alarm_audit`.

mod store;

use hbb_common::{config::Config, log};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hbb_common::tokio;
use serde_json::Value;
use std::sync::Mutex;

/// A few thousand events per file; with the previous file, 2 MB at most.
const MAX_BYTES: u64 = 1024 * 1024;

lazy_static::lazy_static! {
    static ref STORE: Mutex<store::Store> = Mutex::new(store::Store::new(
        Config::path("funti-journal.jsonl").parent().map(Into::into).unwrap_or_default(),
        MAX_BYTES,
    ));
}

fn write(store: &store::Store, event: Value) {
    if let Err(err) = store.append(&event) {
        log::warn!("Connection journal: {}", err);
    }
}

/// `audit` is the record of `post_conn_audit`: `action: new` (not kept: it
/// comes before authorization, from anyone), `action: close`, or the
/// authorized peer.
pub fn conn_event(conn: i32, ip: &str, audit: &Value) {
    let now = hbb_common::get_time();
    let mut store = STORE.lock().unwrap();
    let event = match audit["action"].as_str() {
        Some("close") => store.closed(now, conn),
        Some(_) => None,
        None if audit["peer"].is_array() => Some(store.connected(now, conn, ip, audit)),
        None => None,
    };
    if let Some(event) = event {
        write(&store, event);
    }
}

pub fn file_event(
    conn: i32,
    peer: &str,
    ip: &str,
    received: bool,
    path: &str,
    files: &[(String, i64)],
) {
    let event = store::files(hbb_common::get_time(), conn, peer, ip, received, path, files);
    write(&STORE.lock().unwrap(), event);
}

pub fn alarm_event(conn: i32, alarm: i8, info: &Value) {
    let event = store::refused(hbb_common::get_time(), conn, alarm, info);
    write(&STORE.lock().unwrap(), event);
}

/// How many events the settings page gets.
const PAGE: usize = 300;

/// The newest events as a JSON array, newest first (for the settings page).
/// With `clear` the journal is emptied first; the clearing itself is the
/// first record of the new journal.
pub fn read(clear: bool) -> String {
    let store = STORE.lock().unwrap();
    if clear {
        store.clear();
        let event = serde_json::json!({"t": hbb_common::get_time() / 1000, "kind": "cleared"});
        write(&store, event);
    }
    Value::Array(store.read(PAGE)).to_string()
}

/// From the window: ask the process that accepts connections, which owns
/// the journal. Empty when it does not answer.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
pub async fn read_blocking(clear: bool) -> String {
    use crate::ipc::{connect, Data};
    let Ok(mut c) = connect(1000, "").await else {
        return String::new();
    };
    if c.send(&Data::FuntiJournal(clear, None)).await.is_err() {
        return String::new();
    }
    match c.next_timeout(3000).await {
        Ok(Some(Data::FuntiJournal(_, Some(json)))) => json,
        _ => String::new(),
    }
}
