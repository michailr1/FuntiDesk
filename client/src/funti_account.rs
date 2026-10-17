//! FUNTIDESK (ADR-009/010): an account command never exposes a signing oracle.

use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Clone, Serialize, Deserialize)]
pub struct Packet {
    pub action: String,
    pub payload: String,
}

impl fmt::Debug for Packet {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("FuntiAccountPacket(<redacted>)")
    }
}

pub async fn call(action: String, payload: String) -> String {
    #[cfg(windows)]
    {
        let request = Packet { action, payload };
        let result = async {
            let mut connection = crate::ipc::connect(1000, "").await?;
            connection
                .send(&crate::ipc::Data::FuntiAccount(request, None))
                .await?;
            match connection.next_timeout(150_000).await? {
                Some(crate::ipc::Data::FuntiAccount(reply, Some(true))) => Ok(reply.payload),
                _ => Err(hbb_common::anyhow::anyhow!("invalid account IPC reply")),
            }
        }
        .await;
        return result.unwrap_or_else(|_: hbb_common::anyhow::Error| {
            r#"{"error":"funti-account-service-unavailable"}"#.into()
        });
    }
    #[cfg(not(windows))]
    {
        let _ = (action, payload);
        r#"{"error":"funti-account-unsupported"}"#.into()
    }
}

#[cfg(windows)]
#[path = "funti_account_windows.rs"]
mod windows;
#[cfg(windows)]
pub use windows::{execute, start};

#[cfg(windows)]
#[path = "funti_account_ui.rs"]
mod ui;
#[cfg(windows)]
pub use ui::{call_blocking, start_ui};

#[cfg(not(windows))]
pub fn call_blocking(action: String, payload: String) -> String {
    let _ = (action, payload);
    r#"{"error":"funti-account-unsupported"}"#.into()
}

/// Capture the account before dialing, so a later login cannot inherit this event.
#[cfg(windows)]
pub async fn history_context() -> Option<serde_json::Value> {
    let raw = hbb_common::tokio::time::timeout(
        std::time::Duration::from_millis(500),
        call("status".into(), "{}".into()),
    )
    .await
    .ok()?;
    let state: serde_json::Value = serde_json::from_str(&raw).ok()?;
    if state["library_enabled"] != true || !state["data"]["library"]["history_epoch"].is_i64() {
        return None;
    }
    Some(
        serde_json::json!({"account_id":state["account_id"],"history_epoch":state["data"]["library"]["history_epoch"]}),
    )
}

#[cfg(windows)]
pub fn record_connection(context: Option<serde_json::Value>, id: String, name: String) {
    let Some(mut payload) = context else {
        return;
    };
    payload["funti_id"] = id.into();
    payload["name"] = name.into();
    hbb_common::tokio::spawn(async move {
        let reply = call("history_append".into(), payload.to_string()).await;
        if serde_json::from_str::<serde_json::Value>(&reply)
            .map(|r| !r["error"].is_null())
            .unwrap_or(true)
        {
            hbb_common::throttled_log!(
                std::time::Duration::from_secs(60),
                warn,
                "FuntiDesk: account history synchronization pending or unavailable"
            );
        }
    });
}

#[cfg(windows)]
pub fn favorite_ids() -> Option<Vec<String>> {
    let raw = call_blocking("status".into(), "{}".into());
    let state: serde_json::Value = serde_json::from_str(&raw).ok()?;
    if state["library_enabled"] != true {
        return None;
    }
    Some(
        state["data"]["library"]["favorites"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|row| row["funti_id"].as_str().map(str::to_owned))
            .collect(),
    )
}
