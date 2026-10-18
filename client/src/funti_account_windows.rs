use super::Packet;
use crate::{funti_account_protocol as protocol, funti_family as family};
use hbb_common::{
    anyhow::{anyhow, Result},
    base64::{engine::general_purpose::STANDARD, Engine},
    config::{Config, Config2},
    tokio::{
        self,
        sync::{mpsc, oneshot},
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    sync::{Mutex, RwLock},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const STATE: &str = "funti-account-state-v1";
const API: &str = "https://desk.funti.cc/api/account/v1";
const MAX_RESPONSE: usize = 8 * 1024 * 1024;

lazy_static::lazy_static! {
    static ref COMMANDS: Mutex<Option<mpsc::Sender<Command>>> = Mutex::new(None);
    static ref SNAPSHOT: RwLock<Value> = RwLock::new(json!({"logged_in":false,"bound":false}));
}

struct Command {
    packet: Packet,
    reply: oneshot::Sender<Value>,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    binding: Option<Binding>,
    protected_session: String,
    // Accept the previous opt-in setting when restoring an existing login.
    #[serde(default, rename = "library_account", skip_serializing)]
    _legacy_library_account: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    history_queue: Vec<Value>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    account_id: String,
    device_id: String,
    funti_id: String,
    pk: String,
    ledger: protocol::Ledger,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Session {
    account_id: String,
    token: String,
}

struct Pending {
    context: String,
    challenge: String,
    expires_at: i64,
}
struct Actor {
    http: reqwest::Client,
    stored: Stored,
    session: Option<Session>,
    pending: Option<Pending>,
    cache: Value,
    last_refresh: i64,
    error: Option<&'static str>,
}

pub fn start() {
    let mut commands = COMMANDS.lock().unwrap();
    if commands.is_some() {
        return;
    }
    let (sender, receiver) = mpsc::channel(4);
    *commands = Some(sender);
    tokio::spawn(run(receiver));
}

pub async fn execute(packet: Packet) -> Value {
    if packet.payload.len() > 60 * 1024 {
        return failure("funti-account-invalid-request");
    }
    if packet.action == "status" {
        return SNAPSHOT.read().unwrap().clone();
    }
    if ![
        "request",
        "verify",
        "refresh",
        "logout",
        "logout_all",
        "remove",
        "cancel_removal",
        "dismiss",
        "favorites_set",
        "history_append",
        "history_clear",
    ]
    .contains(&packet.action.as_str())
    {
        return failure("funti-account-invalid-request");
    }
    let sender = COMMANDS.lock().unwrap().clone();
    let Some(sender) = sender else {
        return failure("funti-account-service-unavailable");
    };
    let (reply, receiver) = oneshot::channel();
    if sender.try_send(Command { packet, reply }).is_err() {
        return failure("funti-account-busy");
    }
    receiver
        .await
        .unwrap_or_else(|_| failure("funti-account-service-unavailable"))
}

async fn run(mut commands: mpsc::Receiver<Command>) {
    let loaded = tokio::task::spawn_blocking(Actor::load).await;
    let mut actor = match loaded {
        Ok(Ok(actor)) => actor,
        _ => {
            *SNAPSHOT.write().unwrap() = failure("funti-account-storage-error");
            return;
        }
    };
    let mut timer = tokio::time::interval(Duration::from_secs(60));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    actor.publish();
    loop {
        tokio::select! {
            command = commands.recv() => {
                let Some(command) = command else { break; };
                let result = actor.command(&command.packet).await;
                if let Err(error) = result {
                    actor.error = Some(error);
                    actor.publish();
                    let _ = command.reply.send(failure(error));
                } else {
                    actor.publish();
                    let _ = command.reply.send(SNAPSHOT.read().unwrap().clone());
                }
            },
            _ = timer.tick() => {
                if actor.stored.binding.is_some() || actor.session.is_some() {
                    actor.error = actor.tick().await.err();
                    actor.publish();
                }
            }
        }
    }
}

type Outcome<T> = std::result::Result<T, &'static str>;
fn failure(error: &'static str) -> Value {
    json!({"error":error})
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_secs() as i64)
        .unwrap_or(0)
}
fn own_pk() -> String {
    STANDARD.encode(family::own_pk())
}
fn field(value: &Value, name: &str) -> Outcome<String> {
    value[name]
        .as_str()
        .map(str::to_owned)
        .ok_or("funti-account-invalid-response")
}

impl Actor {
    fn load() -> Result<Self> {
        let raw = Config::get_option(STATE);
        let stored: Stored = if raw.is_empty() {
            Stored::default()
        } else {
            serde_json::from_str(&raw)?
        };
        if let Some(binding) = &stored.binding {
            if !protocol::token(&binding.account_id)
                || !protocol::token(&binding.device_id)
                || binding.ledger.after < 0
                || binding.ledger.pending_ack.len() > 128
                || stored.history_queue.len() > 128
            {
                return Err(anyhow!("invalid account state"));
            }
        }
        let session = if stored.protected_session.is_empty() {
            None
        } else {
            unprotect(&stored.protected_session)
                .ok()
                .and_then(|s| serde_json::from_slice::<Session>(&s).ok())
                .filter(|s| protocol::token(&s.account_id) && protocol::token(&s.token))
        };
        let http = reqwest::Client::builder()
            .use_rustls_tls()
            .https_only(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20))
            .user_agent("FuntiDesk-account")
            .build()?;
        Ok(Self {
            http,
            stored,
            session,
            pending: None,
            cache: json!({}),
            last_refresh: 0,
            error: None,
        })
    }

    fn publish(&self) {
        let binding = self.stored.binding.as_ref();
        *SNAPSHOT.write().unwrap() = json!({
            "logged_in":self.session.is_some(), "bound":binding.is_some(),
            "binding_matches_account":binding.zip(self.session.as_ref()).map(|(b,s)| b.account_id == s.account_id).unwrap_or(false),
            "needs_code":self.pending.as_ref().map(|p| protocol::token(&p.challenge) && p.expires_at > now()).unwrap_or(false),
            "code_expires_at":self.pending.as_ref().map(|p| p.expires_at),
            "last_refresh":self.last_refresh,"data":self.cache,"error":self.error,
            "account_id":self.session.as_ref().map(|s| &s.account_id),
            "device_id":binding.map(|b| &b.device_id),
            "library_enabled":self.library_enabled(),
            "pending_history":self.stored.history_queue.len(),
            "notices":binding.map(|b| &b.ledger.notices),
        });
    }

    async fn api(
        &self,
        route: &str,
        body: Option<Value>,
        bearer: Option<&str>,
        context: Option<&str>,
    ) -> Outcome<Value> {
        let mut request = if let Some(body) = body {
            self.http.post(format!("{API}{route}")).json(&body)
        } else {
            self.http.get(format!("{API}{route}"))
        };
        request = request.header("X-Funti-Client", "native");
        if let Some(token) = bearer {
            request = request.bearer_auth(token);
        }
        if let Some(context) = context {
            request = request.header("X-Funti-Login", context);
        }
        let mut response = request
            .send()
            .await
            .map_err(|_| "funti-account-unavailable")?;
        match response.status().as_u16() {
            401 => return Err("funti-account-session-expired"),
            409 => return Err("funti-account-sync-conflict"),
            429 => return Err("funti-account-try-later"),
            400 => return Err("funti-account-request-rejected"),
            200 | 202 | 204 => {}
            _ => return Err("funti-account-unavailable"),
        }
        if response.status().as_u16() == 204 {
            return Ok(Value::Null);
        }
        if response
            .content_length()
            .map(|n| n > MAX_RESPONSE as u64)
            .unwrap_or(false)
        {
            return Err("funti-account-invalid-response");
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "funti-account-unavailable")?
        {
            if bytes.len() + chunk.len() > MAX_RESPONSE {
                return Err("funti-account-invalid-response");
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| "funti-account-invalid-response")
    }

    async fn save(&mut self, next: Stored) -> Outcome<()> {
        let raw = serde_json::to_string(&next).map_err(|_| "funti-account-storage-error")?;
        tokio::task::spawn_blocking(move || {
            Config2::funti_account_update(|options| {
                options.insert(STATE.into(), raw);
                Ok(())
            })
        })
        .await
        .map_err(|_| "funti-account-storage-error")?
        .map_err(|_| "funti-account-storage-error")?;
        self.stored = next;
        Ok(())
    }

    async fn drop_session(&mut self) -> Outcome<()> {
        self.session = None;
        self.pending = None;
        self.cache = json!({});
        self.last_refresh = 0;
        let mut next = self.stored.clone();
        next.protected_session.clear();
        next.history_queue.clear();
        self.save(next).await
    }

    async fn command(&mut self, packet: &Packet) -> Outcome<()> {
        self.error = None;
        let payload: Value =
            serde_json::from_str(&packet.payload).map_err(|_| "funti-account-invalid-request")?;
        match packet.action.as_str() {
            "request" => {
                let email = payload["email"]
                    .as_str()
                    .filter(|s| s.len() <= 254)
                    .ok_or("funti-account-invalid-request")?;
                let context = if let Some(pending) = &self.pending {
                    pending.context.clone()
                } else {
                    let boot = self.api("/auth/bootstrap", None, None, None).await?;
                    let context = field(&boot, "login_context")?;
                    // Keep the context even if the following mail request loses its reply.
                    self.pending = Some(Pending {
                        context: context.clone(),
                        challenge: String::new(),
                        expires_at: now() + 300,
                    });
                    context
                };
                if !protocol::token(&context) {
                    return Err("funti-account-invalid-response");
                }
                let reply = self
                    .api(
                        "/auth/request",
                        Some(json!({"email":email})),
                        None,
                        Some(&context),
                    )
                    .await?;
                let challenge = field(&reply, "challenge_id")?;
                if !protocol::token(&challenge) {
                    return Err("funti-account-invalid-response");
                }
                self.pending = Some(Pending {
                    context,
                    challenge,
                    expires_at: now() + 300,
                });
            }
            "verify" => {
                let code = payload["code"]
                    .as_str()
                    .filter(|s| s.len() == 6 && s.bytes().all(|b| b.is_ascii_digit()))
                    .ok_or("funti-account-invalid-code")?;
                let pending = self
                    .pending
                    .as_ref()
                    .filter(|p| protocol::token(&p.challenge) && p.expires_at > now())
                    .ok_or("funti-account-invalid-code")?;
                let reply = self
                    .api(
                        "/auth/verify",
                        Some(json!({"challenge_id":pending.challenge,"code":code})),
                        None,
                        Some(&pending.context),
                    )
                    .await
                    .map_err(|e| {
                        if e == "funti-account-request-rejected" {
                            "funti-account-invalid-code"
                        } else {
                            e
                        }
                    })?;
                let session = Session {
                    account_id: field(&reply, "account_id")?,
                    token: field(&reply, "token")?,
                };
                if !protocol::token(&session.account_id) || !protocol::token(&session.token) {
                    return Err("funti-account-invalid-response");
                }
                let bytes =
                    serde_json::to_vec(&session).map_err(|_| "funti-account-storage-error")?;
                let protected = tokio::task::spawn_blocking(move || protect(&bytes))
                    .await
                    .map_err(|_| "funti-account-storage-error")?
                    .map_err(|_| "funti-account-storage-error")?;
                let mut next = self.stored.clone();
                next.protected_session = protected;
                next.history_queue.clear();
                self.save(next).await?;
                self.session = Some(session);
                self.pending = None;
                self.cache = json!({});
                let bound = self.bind().await;
                self.tick().await?;
                bound?;
            }
            "refresh" => {
                self.tick().await?;
            }
            "logout" | "logout_all" => {
                let token = self
                    .session
                    .as_ref()
                    .ok_or("funti-account-session-expired")?
                    .token
                    .clone();
                let route = if packet.action == "logout_all" {
                    "/logout-all"
                } else {
                    "/logout"
                };
                match self.api(route, Some(json!({})), Some(&token), None).await {
                    Ok(_) | Err("funti-account-session-expired") => self.drop_session().await?,
                    Err(error) => return Err(error),
                }
            }
            "remove" => {
                let pk = payload["target_pk"]
                    .as_str()
                    .filter(|s| s.len() == 44)
                    .ok_or("funti-account-invalid-request")?;
                let request_id = payload["request_id"]
                    .as_str()
                    .filter(|s| protocol::token(s))
                    .ok_or("funti-account-invalid-request")?;
                let token = self
                    .session
                    .as_ref()
                    .ok_or("funti-account-session-expired")?
                    .token
                    .clone();
                self.api(
                    "/family/remove",
                    Some(json!({"target_pk":pk,"request_id":request_id})),
                    Some(&token),
                    None,
                )
                .await?;
                self.tick().await?;
            }
            "cancel_removal" => {
                let event = payload["event_id"]
                    .as_i64()
                    .filter(|id| *id > 0)
                    .ok_or("funti-account-invalid-request")?;
                let token = self
                    .session
                    .as_ref()
                    .ok_or("funti-account-session-expired")?
                    .token
                    .clone();
                self.api(
                    "/family/remove/cancel",
                    Some(json!({"event_id":event})),
                    Some(&token),
                    None,
                )
                .await?;
                self.tick().await?;
            }
            "favorites_set" | "history_clear" | "history_append" => {
                self.library_command(&packet.action, payload).await?;
            }
            "dismiss" => {
                let mut next = self.stored.clone();
                if let Some(binding) = &mut next.binding {
                    binding.ledger.notices.clear();
                }
                self.save(next).await?;
            }
            _ => return Err("funti-account-invalid-request"),
        }
        Ok(())
    }

    async fn bind(&mut self) -> Outcome<()> {
        let session = self
            .session
            .as_ref()
            .ok_or("funti-account-session-expired")?;
        if self
            .stored
            .binding
            .as_ref()
            .map(|b| b.account_id != session.account_id)
            .unwrap_or(false)
        {
            return Err("funti-account-key-already-bound");
        }
        let account = session.account_id.clone();
        let token = session.token.clone();
        let funti_id = Config::get_id();
        let pk = own_pk();
        let reply = self
            .api(
                "/devices/bind/nonce",
                Some(json!({"funti_id":funti_id,"pk":pk})),
                Some(&token),
                None,
            )
            .await?;
        let nonce: protocol::Nonce =
            serde_json::from_value(reply).map_err(|_| "funti-account-invalid-response")?;
        let message = nonce
            .message("bind", &account, None, &funti_id, &pk, "", now())
            .ok_or("funti-account-invalid-response")?;
        let signature = family::sign_message(&message);
        if signature.len() != 64 {
            return Err("funti-account-key-changed");
        }
        let reply = self
            .api(
                "/devices/bind",
                Some(
                    json!({"nonce":nonce.nonce,"signature":STANDARD.encode(signature),
            "name":crate::common::hostname(),"version":crate::ui_interface::get_version()}),
                ),
                Some(&token),
                None,
            )
            .await?;
        let device = field(&reply, "device_id")?;
        if !protocol::token(&device) {
            return Err("funti-account-invalid-response");
        }
        let ledger = self
            .stored
            .binding
            .as_ref()
            .filter(|b| b.account_id == account && b.device_id == device && b.pk == pk)
            .map(|b| b.ledger.clone())
            .unwrap_or_default();
        let mut next = self.stored.clone();
        next.binding = Some(Binding {
            account_id: account,
            device_id: device,
            funti_id,
            pk,
            ledger,
        });
        self.save(next).await
    }

    async fn signed(&self, action: &str, payload: Value, bearer: Option<&str>) -> Outcome<Value> {
        let binding = self
            .stored
            .binding
            .as_ref()
            .ok_or("funti-account-not-bound")?;
        if binding.pk != own_pk() {
            return Err("funti-account-key-changed");
        }
        let hash = protocol::payload_hash(&payload).map_err(|_| "funti-account-invalid-request")?;
        let route = format!("/devices/{}/{action}", binding.device_id);
        let reply = self
            .api(
                &format!("{route}/nonce"),
                Some(json!({"payload_hash":hash})),
                bearer,
                None,
            )
            .await?;
        let nonce: protocol::Nonce =
            serde_json::from_value(reply).map_err(|_| "funti-account-invalid-response")?;
        let message = nonce
            .message(
                action,
                &binding.account_id,
                Some(&binding.device_id),
                &binding.funti_id,
                &binding.pk,
                &hash,
                now(),
            )
            .ok_or("funti-account-invalid-response")?;
        let signature = family::sign_message(&message);
        if signature.len() != 64 {
            return Err("funti-account-key-changed");
        }
        self.api(&route, Some(json!({"nonce":nonce.nonce,"signature":STANDARD.encode(signature),"payload":payload})), bearer, None).await
    }

    async fn acknowledge(&mut self) -> Outcome<()> {
        let Some(binding) = &self.stored.binding else {
            return Ok(());
        };
        let events = binding.ledger.pending_ack.clone();
        if events.is_empty() {
            return Ok(());
        }
        self.signed("ack", json!({"events":events}), None).await?;
        let mut next = self.stored.clone();
        if let Some(binding) = &mut next.binding {
            binding.ledger.pending_ack.clear();
        }
        self.save(next).await
    }

    async fn receive(&mut self) -> Outcome<()> {
        self.acknowledge().await?;
        let Some(binding) = &self.stored.binding else {
            return Ok(());
        };
        let reply = self
            .signed("sync", json!({"after":binding.ledger.after}), None)
            .await?;
        let events: Vec<protocol::Event> = serde_json::from_value(reply["events"].clone())
            .map_err(|_| "funti-account-invalid-response")?;
        if events.is_empty() {
            return Ok(());
        }
        let mut next = self.stored.clone();
        let result = tokio::task::spawn_blocking(move || -> Result<Stored> {
            let _mutation = family::mutation_lock();
            Config2::funti_account_update(|options| {
                let raw = options
                    .get(family::OPTION_FAMILY)
                    .map(String::as_str)
                    .unwrap_or("[]");
                let mut members: Vec<family::Member> = serde_json::from_str(raw)?;
                let binding = next
                    .binding
                    .as_mut()
                    .ok_or_else(|| anyhow!("missing binding"))?;
                protocol::apply_events(
                    &mut members,
                    |m| m.pk.as_str(),
                    &mut binding.ledger,
                    &events,
                )
                .map_err(|_| anyhow!("invalid event batch"))?;
                options.insert(
                    family::OPTION_FAMILY.into(),
                    serde_json::to_string(&members)?,
                );
                options.insert(STATE.into(), serde_json::to_string(&next)?);
                Ok(())
            })?;
            Ok(next)
        })
        .await
        .map_err(|_| "funti-account-storage-error")?
        .map_err(|_| "funti-account-storage-error")?;
        self.stored = result;
        self.acknowledge().await
    }

    async fn tick(&mut self) -> Outcome<()> {
        // Revocation delivery is attempted before any work needing email authorization.
        let delivered = self.receive().await;
        let Some(session) = &self.session else {
            return delivered;
        };
        let token = session.token.clone();
        let result = self.refresh_account(&token).await;
        if result == Err("funti-account-session-expired") {
            self.drop_session().await?;
        }
        delivered.and(result)
    }

    fn library_enabled(&self) -> bool {
        self.session.is_some()
    }

    async fn library_command(&mut self, action: &str, payload: Value) -> Outcome<()> {
        let session = self
            .session
            .as_ref()
            .ok_or("funti-account-session-expired")?;
        if !self.library_enabled()
            || payload["account_id"].as_str() != Some(session.account_id.as_str())
        {
            return Err("funti-account-request-rejected");
        }
        let token = session.token.clone();
        if action == "history_append" {
            if self.stored.history_queue.len() >= 128 {
                return Err("funti-account-try-later");
            }
            let Some(binding) = self
                .stored
                .binding
                .as_ref()
                .filter(|b| b.account_id == session.account_id)
            else {
                return Err("funti-account-not-bound");
            };
            if !payload["funti_id"]
                .as_str()
                .map(|id| {
                    !id.is_empty()
                        && id.len() <= 64
                        && id
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
                })
                .unwrap_or(false)
                || payload["name"]
                    .as_str()
                    .map(|name| name.len() > 256 || name.chars().any(char::is_control))
                    .unwrap_or(true)
                || payload["history_epoch"].as_i64()
                    != self.cache["library"]["history_epoch"].as_i64()
            {
                return Err("funti-account-request-rejected");
            }
            let mut next = self.stored.clone();
            let event_id = payload.get("event_id").cloned().unwrap_or_else(|| {
                json!(hex::encode(
                    hbb_common::sodiumoxide::randombytes::randombytes(32)
                ))
            });
            let connected_at = payload
                .get("connected_at")
                .cloned()
                .unwrap_or_else(|| json!(now()));
            if !event_id.as_str().map(protocol::token).unwrap_or(false)
                || !connected_at
                    .as_i64()
                    .map(|time| time > now() - 90 * 86400 && time <= now() + 300)
                    .unwrap_or(false)
            {
                return Err("funti-account-request-rejected");
            }
            if self
                .stored
                .history_queue
                .iter()
                .any(|queued| queued["entry"]["event_id"] == event_id)
            {
                return self.flush_history(&token).await;
            }
            next.history_queue.push(json!({"history_epoch":payload["history_epoch"],"entry":{
                "event_id":event_id,
                "source_device_id":binding.device_id,"funti_id":payload["funti_id"],"name":payload["name"],"connected_at":connected_at
            }}));
            self.save(next).await?;
            return self.flush_history(&token).await;
        }
        let (route, body) = if action == "favorites_set" {
            (
                "/library/favorites",
                json!({"revision":payload["revision"],"favorites":payload["favorites"]}),
            )
        } else {
            (
                "/library/history/clear",
                json!({"history_epoch":payload["history_epoch"]}),
            )
        };
        match self.api(route, Some(body), Some(&token), None).await {
            Ok(library) => {
                self.cache["library"] = library;
            }
            Err("funti-account-sync-conflict") => {
                self.cache["library"] = self.api("/library", None, Some(&token), None).await?;
                return Err("funti-account-sync-conflict");
            }
            Err(error) => return Err(error),
        }
        Ok(())
    }

    async fn flush_history(&mut self, token: &str) -> Outcome<()> {
        for _ in 0..2 {
            let Some(queued) = self.stored.history_queue.first().cloned() else {
                break;
            };
            if queued["history_epoch"] == self.cache["library"]["history_epoch"] {
                match self
                    .api("/library/history", Some(queued), Some(token), None)
                    .await
                {
                    Ok(library) => self.cache["library"] = library,
                    Err("funti-account-sync-conflict") => {
                        self.cache["library"] =
                            self.api("/library", None, Some(token), None).await?;
                        // A remote clear invalidates old events; never retag them with the new epoch.
                    }
                    Err("funti-account-request-rejected") => {}
                    Err(error) => return Err(error),
                }
            }
            let mut next = self.stored.clone();
            next.history_queue.remove(0);
            self.save(next).await?;
        }
        Ok(())
    }

    async fn refresh_account(&mut self, token: &str) -> Outcome<()> {
        let session = self.api("/session", None, Some(token), None).await?;
        let account = field(&session, "account_id")?;
        if self.session.as_ref().map(|s| s.account_id.as_str()) != Some(account.as_str()) {
            return Err("funti-account-invalid-response");
        }
        let devices = self.api("/devices", None, Some(token), None).await?;
        let copies = self.api("/family", None, Some(token), None).await?;
        let removals = self
            .api("/family/removals", None, Some(token), None)
            .await?;
        self.cache = json!({"session":session,"devices":devices["devices"],"sources":copies["sources"],"deliveries":removals["deliveries"],"has_more":removals["has_more"]});
        if self.library_enabled() {
            self.cache["library"] = self.api("/library", None, Some(token), None).await?;
            self.flush_history(token).await?;
        }
        self.last_refresh = now();
        let needs_bind = self
            .stored
            .binding
            .as_ref()
            .map(|b| {
                b.account_id == account && (b.funti_id != Config::get_id() || b.pk != own_pk())
            })
            .unwrap_or(true);
        if needs_bind {
            self.bind().await?;
        }
        if self.stored.binding.as_ref().map(|b| b.account_id.as_str()) == Some(account.as_str()) {
            let members: Vec<_> = family::members()
                .iter()
                .map(|m| json!({"id":m.id,"name":m.name,"pk":m.pk}))
                .collect();
            self.signed("family", json!({"name":crate::common::hostname(),"version":crate::ui_interface::get_version(),"members":members}), Some(token)).await?;
        }
        Ok(())
    }
}

fn protect(bytes: &[u8]) -> Result<String> {
    Ok(STANDARD.encode(dpapi(bytes, true)?))
}
fn unprotect(value: &str) -> Result<Vec<u8>> {
    dpapi(&STANDARD.decode(value)?, false)
}

fn dpapi(bytes: &[u8], encrypt: bool) -> Result<Vec<u8>> {
    use winapi::{
        shared::minwindef::FALSE,
        um::{
            dpapi::{CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN},
            winbase::LocalFree,
            wincrypt::CRYPT_INTEGER_BLOB,
        },
    };
    if bytes.is_empty() || bytes.len() > 4096 {
        return Err(anyhow!("invalid protected session size"));
    }
    let mut input_bytes = bytes.to_vec();
    let mut entropy_bytes = Sha256::digest(Config::get_key_pair().0).to_vec();
    let mut input = CRYPT_INTEGER_BLOB {
        cbData: input_bytes.len() as u32,
        pbData: input_bytes.as_mut_ptr(),
    };
    let mut entropy = CRYPT_INTEGER_BLOB {
        cbData: entropy_bytes.len() as u32,
        pbData: entropy_bytes.as_mut_ptr(),
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // User-scoped DPAPI: an installed service encrypts as its service identity.
    let ok = unsafe {
        if encrypt {
            CryptProtectData(
                &mut input,
                std::ptr::null(),
                &mut entropy,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &mut input,
                std::ptr::null_mut(),
                &mut entropy,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if ok == FALSE {
        return Err(anyhow!("protected session unavailable"));
    }
    let result = if output.pbData.is_null() || output.cbData as usize > 16 * 1024 {
        Err(anyhow!("invalid protected session result"))
    } else {
        Ok(unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec())
    };
    if !output.pbData.is_null() {
        unsafe {
            LocalFree(output.pbData as *mut _);
        }
    }
    input_bytes.fill(0);
    entropy_bytes.fill(0);
    result
}
