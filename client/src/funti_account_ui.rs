//! FUNTIDESK: bridge 1.80 dispatches a normal Rust function to its worker pool.
//! The UI runtime starts once here; the service uses its existing IPC runtime.

use hbb_common::{
    log,
    tokio::{
        self,
        sync::{mpsc, Semaphore},
    },
};
use std::{
    sync::{mpsc as reply_channel, Arc, Mutex},
    time::Duration,
};

struct Request {
    action: String,
    payload: String,
    reply: reply_channel::SyncSender<String>,
}

lazy_static::lazy_static! {
    static ref REQUESTS: Mutex<Option<mpsc::Sender<Request>>> = Mutex::new(None);
    static ref LOCAL_IMPORT: tokio::sync::Mutex<()> = tokio::sync::Mutex::new(());
}

pub fn start_ui() {
    let mut requests = REQUESTS.lock().unwrap();
    if requests.is_some() {
        return;
    }
    let (sender, mut receiver) = mpsc::channel::<Request>(4);
    let started = std::thread::Builder::new()
        .name("funti-account-ffi".into())
        .spawn(move || {
            // Runtime construction is on its dedicated startup thread, outside Tokio.
            // The existing Flutter runner blocks on an online-query queue when idle.
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(_) => {
                    log::warn!("FuntiDesk account: UI runner unavailable");
                    return;
                }
            };
            runtime.block_on(async move {
                let slots = Arc::new(Semaphore::new(8));
                while let Some(request) = receiver.recv().await {
                    let Ok(permit) = slots.clone().try_acquire_owned() else {
                        let _ = request.reply.send(error("funti-account-busy"));
                        continue;
                    };
                    tokio::spawn(async move {
                        let _permit = permit;
                        let status = request.action == "status";
                        let result = super::call(request.action, request.payload).await;
                        let _ = request.reply.send(result.clone());
                        if status {
                            sync_local_library(&result).await;
                        }
                    });
                }
            });
        });
    if started.is_ok() {
        *requests = Some(sender);
    } else {
        log::warn!("FuntiDesk account: UI runner unavailable");
    }
}

async fn sync_local_library(raw: &str) {
    use crate::funti_account_protocol as protocol;
    use hbb_common::config::{LocalConfig, PeerConfig};
    use serde_json::{json, Value};
    use std::time::{SystemTime, UNIX_EPOCH};

    let Ok(_import) = LOCAL_IMPORT.try_lock() else {
        return;
    };
    let Ok(state) = serde_json::from_str::<Value>(raw) else {
        return;
    };
    if state["library_enabled"] != true {
        return;
    }
    let Some(account) = state["account_id"].as_str() else {
        return;
    };
    let library = &state["data"]["library"];
    let Some(favorites) = library["favorites"].as_array() else {
        return;
    };
    let marker = format!("funti-account-local-import-v1-{account}");
    let mut progress: Value = serde_json::from_str(&LocalConfig::get_option(&marker))
        .unwrap_or_else(|_| json!({"favorites":[],"history_done":false}));
    let previous: Vec<String> =
        serde_json::from_value(progress["favorites"].clone()).unwrap_or_default();
    let local_ids = LocalConfig::get_fav();
    if local_ids != previous {
        let ids = local_ids.clone();
        let Ok(local) = tokio::task::spawn_blocking(move || {
            ids.into_iter()
                .map(|id| {
                    let peer = PeerConfig::load(&id);
                    let name = peer
                        .options
                        .get("alias")
                        .cloned()
                        .unwrap_or(peer.info.hostname);
                    let name: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
                    (id, name)
                })
                .collect::<Vec<_>>()
        })
        .await
        else {
            return;
        };
        let merged = protocol::merge_local_favorites(favorites, &previous, &local);
        if &merged != favorites {
            let reply = super::call(
                "favorites_set".into(),
                json!({"account_id":account,"revision":library["revision"],"favorites":merged})
                    .to_string(),
            )
            .await;
            if !serde_json::from_str::<Value>(&reply)
                .map(|r| r["error"].is_null())
                .unwrap_or(false)
            {
                return;
            }
        }
        // Remember local edits, so a remote deletion is not re-added on restart.
        progress["favorites"] = json!(local_ids);
        LocalConfig::set_option(marker.clone(), progress.to_string());
    }
    if progress["history_done"] == true {
        return;
    }
    if library["history_epoch"] == 0 {
        if state["binding_matches_account"] != true {
            return;
        }
        let Some(source) = state["device_id"].as_str() else {
            return;
        };
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let Ok(peers) = tokio::task::spawn_blocking(|| PeerConfig::peers(None)).await else {
            return;
        };
        for (id, modified, peer) in peers.into_iter().take(1000) {
            if library["history"]
                .as_array()
                .map(|rows| {
                    rows.iter()
                        .any(|row| row["source_device_id"] == source && row["funti_id"] == id)
                })
                .unwrap_or(false)
            {
                continue;
            }
            let Ok(modified) = modified.duration_since(UNIX_EPOCH) else {
                continue;
            };
            let name = peer
                .options
                .get("alias")
                .cloned()
                .unwrap_or(peer.info.hostname);
            let name: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
            let Some(mut entry) = protocol::local_history_entry(
                account,
                source,
                &id,
                &name,
                modified.as_secs() as i64,
                now,
            ) else {
                continue;
            };
            entry["account_id"] = account.into();
            entry["history_epoch"] = library["history_epoch"].clone();
            let reply = super::call("history_append".into(), entry.to_string()).await;
            if !serde_json::from_str::<Value>(&reply)
                .map(|r| r["error"].is_null())
                .unwrap_or(false)
            {
                return;
            }
        }
    }
    // A cleared account history is never repopulated from an older local list.
    progress["history_done"] = true.into();
    LocalConfig::set_option(marker, progress.to_string());
}

pub fn call_blocking(action: String, payload: String) -> String {
    // Dart receives a Future; only the bridge's ordinary worker may wait here.
    if tokio::runtime::Handle::try_current().is_ok() {
        return error("funti-account-busy");
    }
    let sender = REQUESTS.lock().unwrap().clone();
    let Some(sender) = sender else {
        return error("funti-account-service-unavailable");
    };
    let (reply, receiver) = reply_channel::sync_channel(1);
    if sender
        .try_send(Request {
            action,
            payload,
            reply,
        })
        .is_err()
    {
        return error("funti-account-busy");
    }
    receiver
        .recv_timeout(Duration::from_secs(155))
        .unwrap_or_else(|_| error("funti-account-service-unavailable"))
}

fn error(key: &str) -> String {
    serde_json::json!({"error":key}).to_string()
}
