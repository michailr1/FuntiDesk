//! FUNTIDESK (ADR-006): family access — devices paired once by a one-time
//! code, then a member logs in by signing the connection challenge with its
//! device key instead of a password. The person at the computer still has to
//! accept every session. The family list lives on each device, in the
//! service's own config; the FuntiDesk server knows nothing about families.

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hbb_common::tokio;
use hbb_common::{
    config::Config,
    log,
    rand::{self, Rng},
    sodiumoxide::{
        base64::{self, Variant},
        crypto::sign,
    },
};
use serde_derive::{Deserialize, Serialize};
use std::{
    convert::TryFrom,
    sync::Mutex,
    time::{Duration, Instant},
};

/// Service option holding the family list as JSON.
pub const OPTION_FAMILY: &str = "funti-family";
/// What a signature is for; part of the signed message.
pub const KIND_PAIR: &str = "pair";
pub const KIND_LOGIN: &str = "login";
pub const KIND_HELP: &str = "help";
pub const KIND_UNPAIR: &str = "unpair";
/// Login errors used by pairing and help requests.
pub const LOGIN_MSG_PAIRED: &str = "funti-family-paired";
pub const LOGIN_MSG_PAIR_FAILED: &str = "funti-family-pair-failed";
pub const LOGIN_MSG_HELP_DELIVERED: &str = "funti-help-delivered";
pub const LOGIN_MSG_HELP_REFUSED: &str = "funti-help-refused";
pub const LOGIN_MSG_UNPAIRED: &str = "funti-family-unpaired";

const PAIR_CODE_TTL: Duration = Duration::from_secs(600);
const HELP_TTL: Duration = Duration::from_secs(600);

lazy_static::lazy_static! {
    static ref PAIR_CODE: Mutex<Option<(String, Instant)>> = Default::default();
    // Family members asked for help from this computer: their next family
    // login here is accepted without "Accept" (the person asked themselves).
    static ref HELP_ALLOWED: Mutex<std::collections::HashMap<String, Instant>> = Default::default();
    // Members just removed here: the "leave" message to them is still signed
    // for a short while, so removing here does not wait for the network.
    static ref LEAVING: Mutex<std::collections::HashMap<String, Instant>> = Default::default();
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Member {
    pub id: String,
    pub name: String,
    /// Ed25519 device public key, base64.
    pub pk: String,
}

impl Member {
    fn pk_bytes(&self) -> Option<Vec<u8>> {
        base64::decode(&self.pk, Variant::Original).ok()
    }
}

pub fn members() -> Vec<Member> {
    serde_json::from_str(&Config::get_option(OPTION_FAMILY)).unwrap_or_default()
}

fn store(members: &[Member]) {
    Config::set_option(
        OPTION_FAMILY.to_owned(),
        serde_json::to_string(members).unwrap_or_default(),
    );
}

pub fn member(id: &str) -> Option<Member> {
    members().into_iter().find(|m| m.id == id)
}

/// Adds or replaces the member with this id.
pub fn add(id: &str, name: &str, pk: &[u8]) {
    let mut list: Vec<Member> = members().into_iter().filter(|m| m.id != id).collect();
    list.push(Member {
        id: id.to_owned(),
        name: name.to_owned(),
        pk: base64::encode(pk, Variant::Original),
    });
    store(&list);
    log::info!("FuntiDesk family: {} ({}) added", id, name);
}

const LEAVING_TTL: Duration = Duration::from_secs(120);

/// Removes the member here at once and keeps signing "leave" to it for two
/// minutes (the notice to the other computer goes out in the background).
pub fn remove_and_leave(id: &str) {
    LEAVING
        .lock()
        .unwrap()
        .insert(id.to_owned(), Instant::now());
    remove(id);
}

/// True while a "leave" message to a just removed member may be signed.
pub fn is_leaving(id: &str) -> bool {
    let mut map = LEAVING.lock().unwrap();
    map.retain(|_, at| at.elapsed() < LEAVING_TTL);
    map.contains_key(id)
}

/// Removes the member with this id.
pub fn remove(id: &str) {
    let list: Vec<Member> = members().into_iter().filter(|m| m.id != id).collect();
    store(&list);
    log::info!("FuntiDesk family: {} removed", id);
}

/// The message a device signs: bound to one connection (challenge), to the
/// computer being entered (host) and to the signer (guest).
pub fn message(kind: &str, challenge: &str, host_id: &str, guest_id: &str) -> Vec<u8> {
    format!("funtidesk-family-v1\n{kind}\n{challenge}\n{host_id}\n{guest_id}").into_bytes()
}

/// This device's public key.
pub fn own_pk() -> Vec<u8> {
    Config::get_key_pair().1
}

/// Signs with this device's key. Empty on a broken key.
pub fn sign_message(msg: &[u8]) -> Vec<u8> {
    let (sk, _) = Config::get_key_pair();
    match sign::SecretKey::from_slice(&sk) {
        Some(sk) => sign::sign_detached(msg, &sk).to_bytes().to_vec(),
        None => Vec::new(),
    }
}

pub fn verify(pk: &[u8], msg: &[u8], sig: &[u8]) -> bool {
    let (Some(pk), Ok(sig)) = (sign::PublicKey::from_slice(pk), sign::Signature::try_from(sig))
    else {
        return false;
    };
    sign::verify_detached(&sig, msg, &pk)
}

/// Verifies a member's login signature for this connection.
pub fn verify_member_login(guest_id: &str, challenge: &str, sig: &[u8]) -> bool {
    verify_member(KIND_LOGIN, guest_id, challenge, sig)
}

/// Verifies a member's signature of `kind` for this connection.
pub fn verify_member(kind: &str, guest_id: &str, challenge: &str, sig: &[u8]) -> bool {
    let Some(pk) = member(guest_id).and_then(|m| m.pk_bytes()) else {
        return false;
    };
    verify(&pk, &message(kind, challenge, &Config::get_id(), guest_id), sig)
}

/// This computer asked `id` for help: allow one login from it without
/// "Accept" for the next 10 minutes.
pub fn allow_help(id: &str) {
    let mut map = HELP_ALLOWED.lock().unwrap();
    map.retain(|_, at| at.elapsed() < HELP_TTL);
    map.insert(id.to_owned(), Instant::now());
}

/// One-time check: did this computer ask `id` for help recently?
pub fn take_help(id: &str) -> bool {
    let mut map = HELP_ALLOWED.lock().unwrap();
    map.retain(|_, at| at.elapsed() < HELP_TTL);
    map.remove(id).is_some()
}

/// Starts pairing on this computer: a new 6-digit code, valid 10 minutes;
/// any older code is dropped.
pub fn new_pair_code() -> String {
    let code = format!("{:06}", rand::thread_rng().gen_range(0..1_000_000u32));
    *PAIR_CODE.lock().unwrap() = Some((code.clone(), Instant::now()));
    code
}

/// Drops the pairing code shown on this computer.
pub fn cancel_pair_code() {
    *PAIR_CODE.lock().unwrap() = None;
}

/// One-time check of the pairing code.
pub fn take_pair_code(code: &str) -> bool {
    let mut lock = PAIR_CODE.lock().unwrap();
    let ok = match lock.as_ref() {
        Some((c, at)) => at.elapsed() < PAIR_CODE_TTL && constant_time_eq(c.as_bytes(), code.as_bytes()),
        None => false,
    };
    if ok {
        *lock = None;
    }
    ok
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// Client side: the UI process asks its own service (which holds the device
// key and the family list) over IPC, and pairs by a headless connection.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod client_side {
    use super::*;
    use crate::client::{Client, Data, Interface, LoginConfigHandler};
    use crate::ipc::{self, Data as IpcData};
    use async_trait::async_trait;
    use hbb_common::{
        message_proto::*,
        protobuf::Message as _,
        rendezvous_proto::ConnType,
        tokio::time::{timeout, Duration as TokioDuration},
        Stream,
    };
    use std::sync::{Arc, RwLock};

    /// (signature, own public key) from the service; None when it refuses
    /// (a login to a computer that is not in the family) or is unreachable.
    pub async fn request_sign(kind: &str, challenge: &str, host_id: &str) -> Option<(Vec<u8>, Vec<u8>)> {
        let mut conn = ipc::connect(1000, "").await.ok()?;
        conn.send(&IpcData::FuntiFamilySign(
            kind.to_owned(),
            challenge.to_owned(),
            host_id.to_owned(),
            None,
        ))
        .await
        .ok()?;
        match conn.next_timeout(2000).await {
            Ok(Some(IpcData::FuntiFamilySign(_, _, _, Some((sig, pk))))) if !sig.is_empty() => {
                Some((sig, pk))
            }
            _ => None,
        }
    }

    /// A new pairing code shown on this computer (start), or cancel it.
    pub async fn request_code(start: bool) -> Option<String> {
        let mut conn = ipc::connect(1000, "").await.ok()?;
        conn.send(&IpcData::FuntiFamilyCode(start, None)).await.ok()?;
        match conn.next_timeout(2000).await {
            Ok(Some(IpcData::FuntiFamilyCode(_, Some(code)))) => Some(code),
            _ => None,
        }
    }

    async fn add_via_service(id: &str, name: &str, pk: &[u8]) -> bool {
        let Ok(mut conn) = ipc::connect(1000, "").await else {
            return false;
        };
        conn.send(&IpcData::FuntiFamilyAdd(id.to_owned(), name.to_owned(), pk.to_vec()))
            .await
            .is_ok()
    }

    /// Minimal client interface for the pairing connection: no UI, no session.
    #[derive(Clone)]
    struct PairInterface {
        lc: Arc<RwLock<LoginConfigHandler>>,
    }

    #[async_trait]
    impl Interface for PairInterface {
        fn send(&self, _data: Data) {}
        fn msgbox(&self, msgtype: &str, title: &str, text: &str, _link: &str) {
            log::info!("FuntiDesk family pairing: {} {} {}", msgtype, title, text);
        }
        fn handle_login_error(&self, _err: &str) -> bool {
            false
        }
        fn handle_peer_info(&self, _pi: PeerInfo) {}
        fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}
        async fn handle_hash(&self, _pass: &str, _hash: Hash, _peer: &mut Stream) {}
        async fn handle_login_from_ui(
            &self,
            _os_username: String,
            _os_password: String,
            _password: String,
            _remember: bool,
            _peer: &mut Stream,
        ) {
        }
        async fn handle_test_delay(&self, _t: TestDelay, _peer: &mut Stream) {}
        fn get_lch(&self) -> Arc<RwLock<LoginConfigHandler>> {
            self.lc.clone()
        }
    }

    enum Request {
        Pair(String),
        Help,
        Unpair,
    }

    /// One login to computer `id` without UI: pairing by code, or a help
    /// request signed with the device key. Returns the login answer and the
    /// other computer's key, proven during the handshake (SignedId checked
    /// against the FuntiDesk server key).
    async fn headless(id: &str, request: Request) -> Result<(LoginResponse, Vec<u8>), String> {
        let mut lc = LoginConfigHandler::default();
        lc.initialize(id.to_owned(), ConnType::DEFAULT_CONN, None, false, None, None, None);
        let iface = PairInterface {
            lc: Arc::new(RwLock::new(lc)),
        };
        // The FuntiDesk server key, as a normal session passes it.
        let key = crate::get_key(false).await;
        let ((mut peer, _direct, pk, _kcp, _stream_type), _) =
            Client::start(id, &key, "", ConnType::DEFAULT_CONN, iface.clone())
                .await
                .map_err(|e| e.to_string())?;
        let Some(peer_pk) = pk else {
            return Err("no verified key of the other computer".to_owned());
        };
        loop {
            let bytes = match timeout(TokioDuration::from_secs(30), peer.next()).await {
                Ok(Some(Ok(bytes))) => bytes,
                Ok(Some(Err(e))) => return Err(e.to_string()),
                Ok(None) => return Err("connection closed".to_owned()),
                Err(_) => return Err("timeout".to_owned()),
            };
            let Ok(msg) = Message::parse_from_bytes(&bytes) else {
                continue;
            };
            match msg.union {
                Some(message::Union::Hash(hash)) => {
                    let kind = match request {
                        Request::Pair(_) => KIND_PAIR,
                        Request::Help => KIND_HELP,
                        Request::Unpair => KIND_UNPAIR,
                    };
                    let (sig, own_pk) = request_sign(kind, &hash.challenge, id)
                        .await
                        .ok_or_else(|| "funti-family-not-member".to_owned())?;
                    let mut login = iface
                        .lc
                        .read()
                        .unwrap()
                        .create_login_msg(String::new(), String::new(), Vec::new());
                    if let Some(message::Union::LoginRequest(lr)) = login.union.as_mut() {
                        match &request {
                            Request::Pair(code) => {
                                lr.funti_family_pair = hbb_common::protobuf::MessageField::some(
                                    FuntiFamilyPair {
                                        code: code.clone(),
                                        pk: own_pk.into(),
                                        signature: sig.into(),
                                        ..Default::default()
                                    },
                                );
                            }
                            Request::Help => {
                                lr.funti_help_request = true;
                                lr.funti_family_proof = sig.into();
                            }
                            Request::Unpair => {
                                lr.funti_family_unpair = true;
                                lr.funti_family_proof = sig.into();
                            }
                        }
                    }
                    peer.send(&login).await.map_err(|e| e.to_string())?;
                }
                Some(message::Union::LoginResponse(res)) => return Ok((res, peer_pk.clone())),
                _ => {}
            }
        }
    }

    fn login_error(res: &LoginResponse) -> String {
        match &res.union {
            Some(login_response::Union::Error(err)) => err.clone(),
            _ => "unexpected answer".to_owned(),
        }
    }

    /// Pairs this device with computer `id` using the code shown there.
    /// Ok(name of that computer) once both sides keep each other's key.
    pub async fn pair_with(id: &str, code: &str) -> Result<String, String> {
        let id = id.replace(' ', "");
        let (res, peer_pk) = headless(&id, Request::Pair(code.trim().to_owned())).await?;
        if login_error(&res) != LOGIN_MSG_PAIRED {
            return Err(login_error(&res));
        }
        let name = if res.funti_family_paired.is_empty() {
            id.clone()
        } else {
            res.funti_family_paired.clone()
        };
        if add_via_service(&id, &name, &peer_pk).await {
            Ok(name)
        } else {
            Err("FuntiDesk service is not running".to_owned())
        }
    }

    /// Removes `id` from the family here (at once) and asks that computer to
    /// remove this one too, so that removing is mutual.
    pub async fn leave(id: &str) -> Result<(), String> {
        let mut conn = ipc::connect(1000, "").await.map_err(|e| e.to_string())?;
        conn.send(&IpcData::FuntiFamilyRemove(id.to_owned()))
            .await
            .map_err(|e| e.to_string())?;
        // Let the service apply it before the UI reads the list again.
        conn.next_timeout(1000).await.ok();
        let (res, _) = headless(id, Request::Unpair).await?;
        match login_error(&res).as_str() {
            LOGIN_MSG_UNPAIRED => Ok(()),
            err => Err(err.to_owned()),
        }
    }

    /// Asks family member `id` for help. Before connecting, our service
    /// allows one login from `id` without "Accept" (the person here asked).
    pub async fn ask_help(id: &str) -> Result<(), String> {
        let mut conn = ipc::connect(1000, "").await.map_err(|e| e.to_string())?;
        conn.send(&IpcData::FuntiHelpAllow(id.to_owned()))
            .await
            .map_err(|e| e.to_string())?;
        let (res, _) = headless(id, Request::Help).await?;
        match login_error(&res).as_str() {
            LOGIN_MSG_HELP_DELIVERED => Ok(()),
            err => Err(err.to_owned()),
        }
    }
}
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub use client_side::{ask_help, leave, pair_with, request_code, request_sign};

/// Blocking wrappers for the UI bridge.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
pub async fn code_blocking(start: bool) -> String {
    request_code(start).await.unwrap_or_default()
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
pub async fn pair_blocking(id: &str, code: &str) -> Result<String, String> {
    pair_with(id, code).await
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
pub async fn help_blocking(id: &str) -> Result<(), String> {
    ask_help(id).await
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
pub async fn leave_blocking(id: &str) -> Result<(), String> {
    leave(id).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signature_roundtrip_is_bound_to_message() {
        let (pk, sk) = sign::gen_keypair();
        let msg = message(KIND_LOGIN, "abc123", "111", "222");
        let sig = sign::sign_detached(&msg, &sk).to_bytes().to_vec();
        assert!(verify(&pk.0, &msg, &sig));
        let other = message(KIND_LOGIN, "abc124", "111", "222");
        assert!(!verify(&pk.0, &other, &sig));
        let other_host = message(KIND_LOGIN, "abc123", "333", "222");
        assert!(!verify(&pk.0, &other_host, &sig));
        assert!(!verify(&pk.0, &msg, &sig[..10]));
    }

    #[test]
    fn pair_code_is_one_time() {
        let code = new_pair_code();
        assert_eq!(code.len(), 6);
        assert!(!take_pair_code("x"));
        assert!(take_pair_code(&code));
        assert!(!take_pair_code(&code));
    }
}
