//! FUNTIDESK (ADR-024): service connections of the administrator's
//! workplace — an authorized connection to a host with no video, input or
//! files, only the administration requests (ADR-023). One per host while the
//! workplace shows it; opened with the saved password or as a family member,
//! never with a prompt.
//!
//! The window gets "funti_service" events: `state` ("connecting", "ready",
//! or "closed" with `reason`) and `result` (an answer of the host, JSON).

use crate::client::{Client, Data, Interface, LoginConfigHandler};
use async_trait::async_trait;
use base::message_proto::*;
use hbb_common::{
    log,
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    tokio::{
        self,
        sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender},
        time::{timeout, Duration},
    },
    Stream,
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, RwLock},
};

/// Hosts connected at once at most.
const HOSTS_MAX: usize = 50;
/// A host that says nothing for this long is gone (it answers the test
/// delay of its side every few seconds).
const SILENCE: Duration = Duration::from_secs(90);

pub const REASON_NO_ACCESS: &str = "funti-service-no-access";
pub const REASON_OLD: &str = "funti-service-old-version";
pub const REASON_OFFLINE: &str = "funti-service-offline";

enum Command {
    Request(String),
    Close,
}

lazy_static::lazy_static! {
    static ref HOSTS: Mutex<HashMap<String, UnboundedSender<Command>>> = Default::default();
}

fn event(id: &str, fields: &[(&str, &str)]) {
    let mut data: HashMap<&str, &str> = HashMap::from([("name", "funti_service"), ("id", id)]);
    data.extend(fields.iter().copied());
    #[cfg(feature = "flutter")]
    crate::flutter::push_global_event(
        crate::flutter::APP_TYPE_MAIN,
        serde_json::to_string(&data).unwrap_or_default(),
    );
    #[cfg(not(feature = "flutter"))]
    let _ = data;
}

/// Opens the service connection to host `id`; no-op if it is open already.
pub fn open(id: String) {
    let (tx, rx) = unbounded_channel();
    {
        let mut hosts = HOSTS.lock().unwrap();
        if hosts.contains_key(&id) || hosts.len() >= HOSTS_MAX {
            return;
        }
        hosts.insert(id.clone(), tx);
    }
    std::thread::spawn(move || {
        event(&id, &[("state", "connecting")]);
        let reason = run_blocking(&id, rx);
        HOSTS.lock().unwrap().remove(&id);
        log::info!("FuntiDesk service connection to {} closed: {}", id, reason);
        event(&id, &[("state", "closed"), ("reason", &reason)]);
    });
}

/// Sends an administration request (JSON with "op") to host `id`.
pub fn request(id: &str, json: String) {
    if let Some(tx) = HOSTS.lock().unwrap().get(id) {
        tx.send(Command::Request(json)).ok();
    }
}

pub fn close(id: &str) {
    if let Some(tx) = HOSTS.lock().unwrap().get(id) {
        tx.send(Command::Close).ok();
    }
}

pub fn close_all() {
    for tx in HOSTS.lock().unwrap().values() {
        tx.send(Command::Close).ok();
    }
}

/// No window: a prompt or a login error ends the connection with a reason.
#[derive(Clone)]
struct Quiet {
    lc: Arc<RwLock<LoginConfigHandler>>,
    failed: Arc<Mutex<Option<String>>>,
}

impl Quiet {
    fn fail(&self, reason: &str) {
        self.failed.lock().unwrap().get_or_insert_with(|| reason.to_owned());
    }
}

#[async_trait]
impl Interface for Quiet {
    fn send(&self, _data: Data) {}
    fn msgbox(&self, msgtype: &str, _title: &str, text: &str, _link: &str) {
        // "input-password" and the like: nobody to ask here.
        if msgtype.contains("error") && !text.is_empty() {
            self.fail(text);
        } else {
            self.fail(REASON_NO_ACCESS);
        }
    }
    fn handle_login_error(&self, err: &str) -> bool {
        self.fail(err);
        false
    }
    fn handle_peer_info(&self, _pi: PeerInfo) {}
    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}
    async fn handle_hash(
        &self,
        pass: &str,
        hash: Hash,
        trust: &mut crate::trusted_devices::client::Session,
        peer: &mut Stream,
    ) -> bool {
        crate::client::handle_hash(self.lc.clone(), pass, hash, self, trust, peer).await
    }
    async fn handle_login_from_ui(
        &self,
        _os_username: String,
        _os_password: String,
        _password: String,
        _remember: bool,
        _trust: &mut crate::trusted_devices::client::Session,
        _peer: &mut Stream,
    ) {
    }
    async fn handle_test_delay(&self, t: TestDelay, peer: &mut Stream) {
        crate::client::handle_test_delay(t, peer).await;
    }
    fn get_lch(&self) -> Arc<RwLock<LoginConfigHandler>> {
        self.lc.clone()
    }
}

#[tokio::main(flavor = "current_thread")]
async fn run_blocking(id: &str, rx: UnboundedReceiver<Command>) -> String {
    run(id, rx).await.unwrap_or_else(|reason| reason)
}

/// Ok: closed by this side. Err: why the connection ended.
async fn run(id: &str, mut rx: UnboundedReceiver<Command>) -> Result<String, String> {
    let mut lc = LoginConfigHandler::default();
    lc.initialize(id.to_owned(), ConnType::FILE_TRANSFER, None, false, None, None, None, "");
    lc.funti_service = true;
    let iface = Quiet {
        lc: Arc::new(RwLock::new(lc)),
        failed: Default::default(),
    };
    let failed = |iface: &Quiet| iface.failed.lock().unwrap().clone();
    let key = crate::get_key(false).await;
    let ((mut peer, _direct, pk, _kcp, _stream_type), _) =
        Client::start(id, &key, "", ConnType::FILE_TRANSFER, iface.clone())
            .await
            .map_err(|e| {
                log::info!("FuntiDesk service connection to {}: {}", id, e);
                REASON_OFFLINE.to_owned()
            })?;
    // Fail closed: the host must have proved its key, as in the headless
    // family requests.
    if pk.is_none() || !peer.is_secured() {
        return Err("no verified key of the other computer".to_owned());
    }
    let mut trust = crate::trusted_devices::client::Session::new(
        &iface.lc.read().unwrap(),
        peer.is_secured(),
        pk.as_deref(),
    )
    .map_err(|e| e.to_string())?;
    let mut ready = false;
    loop {
        tokio::select! {
            command = rx.recv() => match command {
                Some(Command::Request(json)) if ready => {
                    let mut misc = Misc::new();
                    misc.set_funti_admin_request(json);
                    let mut msg = Message::new();
                    msg.set_misc(misc);
                    peer.send(&msg).await.map_err(|e| e.to_string())?;
                }
                Some(Command::Request(_)) => {}
                Some(Command::Close) | None => return Ok("closed".to_owned()),
            },
            received = timeout(SILENCE, peer.next()) => {
                let bytes = match received {
                    Ok(Some(Ok(bytes))) => bytes,
                    Ok(Some(Err(e))) => return Err(e.to_string()),
                    Ok(None) | Err(_) => return Err(REASON_OFFLINE.to_owned()),
                };
                let Ok(msg) = Message::parse_from_bytes(&bytes) else { continue };
                match msg.union {
                    Some(message::Union::Hash(hash)) => {
                        if !iface.handle_hash("", hash, &mut trust, &mut peer).await {
                            return Err(failed(&iface).unwrap_or_else(|| REASON_NO_ACCESS.to_owned()));
                        }
                    }
                    Some(message::Union::LoginResponse(res)) => match res.union {
                        Some(login_response::Union::PeerInfo(pi)) => {
                            let service = serde_json::from_str::<serde_json::Value>(&pi.platform_additions)
                                .map(|v| v["funti_service"] == true)
                                .unwrap_or(false);
                            if !service {
                                // An older FuntiDesk opened a file transfer.
                                return Err(REASON_OLD.to_owned());
                            }
                            ready = true;
                            event(id, &[("state", "ready")]);
                        }
                        Some(login_response::Union::Error(err)) => return Err(err),
                        _ => {}
                    },
                    Some(message::Union::TestDelay(t)) => {
                        iface.handle_test_delay(t, &mut peer).await;
                    }
                    Some(message::Union::Misc(misc)) => match misc.union {
                        Some(misc::Union::FuntiAdminResult(json)) => event(id, &[("result", &json)]),
                        Some(misc::Union::CloseReason(reason)) => return Err(reason),
                        _ => {}
                    },
                    _ => {}
                }
                if let Some(reason) = failed(&iface) {
                    return Err(reason);
                }
            }
        }
    }
}
