use anyhow::{bail, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[async_trait]
pub trait KeyRegistry: Send + Sync {
    async fn key(&self, id: &str) -> Result<Option<[u8; 32]>>;
}

pub struct UnixRegistry(pub PathBuf);

#[async_trait]
impl KeyRegistry for UnixRegistry {
    async fn key(&self, id: &str) -> Result<Option<[u8; 32]>> {
        if !crate::crypto::valid_id(id) {
            bail!("invalid ID");
        }
        #[cfg(unix)]
        {
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                #[derive(Serialize)]
                struct Request<'a> {
                    id: &'a str,
                }
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Reply {
                    pk: Option<String>,
                }
                let stream = tokio::net::UnixStream::connect(&self.0).await?;
                let mut stream = BufReader::new(stream);
                let mut message = serde_json::to_vec(&Request { id })?;
                message.push(b'\n');
                stream.get_mut().write_all(&message).await?;
                let mut response = Vec::new();
                use tokio::io::AsyncReadExt;
                stream.take(256).read_until(b'\n', &mut response).await?;
                if response.last() != Some(&b'\n') {
                    bail!("invalid registry response");
                }
                let reply: Reply = serde_json::from_slice(&response)?;
                reply
                    .pk
                    .map(|pk| crate::crypto::public_key(&pk))
                    .transpose()
            })
            .await?
        }
        #[cfg(not(unix))]
        bail!("account service requires a Unix registry socket")
    }
}
