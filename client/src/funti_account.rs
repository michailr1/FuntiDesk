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
