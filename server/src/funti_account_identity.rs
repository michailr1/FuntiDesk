// FUNTIDESK (ADR-010): optional, read-only device-key resolver for account.
// Its failure disables account binding, never the rendezvous service.

use crate::peer::PeerMap;
use hbb_common::{log, tokio, ResultType};

pub(crate) async fn start(pm: PeerMap) {
    let Ok(path) = std::env::var("FUNTI_ACCOUNT_IDENTITY_SOCKET") else {
        return;
    };
    #[cfg(unix)]
    if !matches!(
        tokio::time::timeout(std::time::Duration::from_secs(3), listen(pm, path)).await,
        Ok(Ok(()))
    ) {
        log::warn!("FUNTIDESK: account identity resolver unavailable");
    }
    #[cfg(not(unix))]
    {
        let _ = (pm, path);
        log::warn!("FUNTIDESK: account identity resolver requires Unix");
    }
}

#[cfg(unix)]
async fn listen(pm: PeerMap, path: String) -> ResultType<()> {
    use std::{
        io::ErrorKind,
        os::unix::fs::{chown, FileTypeExt, PermissionsExt},
        path::Path,
    };
    use tokio::{
        io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
        net::{UnixListener, UnixStream},
        sync::Semaphore,
        time::{timeout, Duration},
    };
    let path = Path::new(&path);
    if !path.is_absolute() {
        hbb_common::bail!("socket path must be absolute");
    }
    let gid: u32 = std::env::var("FUNTI_ACCOUNT_IDENTITY_GID")
        .unwrap_or_else(|_| "10001".into())
        .parse()?;
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if !metadata.file_type().is_socket() {
            hbb_common::bail!("unexpected socket path entry");
        }
        match UnixStream::connect(path).await {
            Ok(_) => hbb_common::bail!("socket already in use"),
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::ConnectionRefused | ErrorKind::NotFound
                ) =>
            {
                std::fs::remove_file(path)?
            }
            Err(error) => return Err(error.into()),
        }
    }
    let listener = UnixListener::bind(path)?;
    chown(path, None, Some(gid))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660))?;
    let permits = std::sync::Arc::new(Semaphore::new(16));
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                log::warn!("FUNTIDESK: account identity resolver stopped");
                break;
            };
            let Ok(permit) = permits.clone().try_acquire_owned() else {
                continue;
            };
            let pm = pm.clone();
            tokio::spawn(async move {
                let _permit = permit;
                let _ = timeout(Duration::from_secs(3), async move {
                    #[derive(serde::Deserialize)]
                    #[serde(deny_unknown_fields)]
                    struct Request {
                        id: String,
                    }
                    let mut reader = BufReader::new(stream).take(256);
                    let mut bytes = Vec::new();
                    reader.read_until(b'\n', &mut bytes).await?;
                    if bytes.last() != Some(&b'\n') {
                        return Ok::<(), hbb_common::anyhow::Error>(());
                    }
                    let request: Request = serde_json::from_slice(&bytes)?;
                    if request.id.is_empty()
                        || request.id.len() > 64
                        || !request
                            .id
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                    {
                        return Ok(());
                    }
                    let pk = match pm.get(&request.id).await {
                        Some(peer) => {
                            let peer = peer.read().await;
                            (peer.pk.len() == 32).then(|| base64::encode(&peer.pk))
                        }
                        None => None,
                    };
                    let mut response = serde_json::to_vec(&serde_json::json!({"pk":pk}))?;
                    response.push(b'\n');
                    reader.into_inner().get_mut().write_all(&response).await?;
                    Ok(())
                })
                .await;
            });
        }
    });
    Ok(())
}
