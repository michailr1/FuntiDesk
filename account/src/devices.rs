use crate::{
    crypto,
    store::{active_in, new_event, quotas, Auth, Store},
    web::{self, ApiResult},
    App,
};
use anyhow::Result;
use axum::{
    extract::{ConnectInfo, Path, State},
    http::HeaderMap,
    routing::{get, post},
    Json, Router,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::SocketAddr;

const MAX_DEVICES: i64 = 64;
const MAX_MEMBERS: usize = 128;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FamilyMember {
    pub id: String,
    pub name: String,
    pub pk: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FamilyPayload {
    pub name: String,
    pub version: String,
    pub members: Vec<FamilyMember>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SyncPayload {
    pub after: i64,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AckPayload {
    pub events: Vec<i64>,
}

#[derive(Serialize)]
pub struct Device {
    pub device_id: String,
    pub funti_id: String,
    pub pk: String,
    pub name: String,
    pub version: String,
    pub bound_at: i64,
    pub last_seen: Option<i64>,
}

#[derive(Serialize)]
pub struct FamilyCopy {
    pub source_device_id: String,
    pub source_name: String,
    pub revision: i64,
    pub updated_at: i64,
    pub members: Vec<FamilyMember>,
}

#[derive(Clone, Serialize)]
pub struct Nonce {
    pub nonce: String,
    pub account_id: String,
    pub device_id: Option<String>,
    pub action: String,
    pub funti_id: String,
    pub pk: String,
    pub payload_hash: String,
    pub expires_at: i64,
    #[serde(skip)]
    pub session_hash: Option<String>,
}

impl Nonce {
    pub fn message(&self) -> Vec<u8> {
        if self.action == "bind" {
            format!(
                "funtidesk-account-v1\nbind\n{}\n{}\n{}\n{}\n{}",
                self.account_id, self.funti_id, self.pk, self.nonce, self.expires_at
            )
            .into_bytes()
        } else {
            format!(
                "funtidesk-account-v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
                self.action,
                self.account_id,
                self.device_id.as_deref().unwrap_or(""),
                self.funti_id,
                self.pk,
                self.payload_hash,
                self.nonce,
                self.expires_at
            )
            .into_bytes()
        }
    }
}

pub fn payload_hash<T: Serialize>(payload: &T) -> Result<String> {
    let value = serde_json::to_value(payload)?;
    Ok(crypto::digest(&serde_json::to_vec(&value)?))
}

fn label(value: &str, limit: usize) -> bool {
    !value.trim().is_empty() && value.len() <= limit && !value.chars().any(char::is_control)
}

fn family_valid(value: &FamilyPayload) -> bool {
    label(&value.name, 256)
        && label(&value.version, 64)
        && value.members.len() <= MAX_MEMBERS
        && value.members.iter().all(|m| {
            crypto::valid_id(&m.id) && label(&m.name, 256) && crypto::public_key(&m.pk).is_ok()
        })
        && value
            .members
            .iter()
            .map(|m| &m.pk)
            .collect::<std::collections::HashSet<_>>()
            .len()
            == value.members.len()
}

impl Store {
    pub fn devices(&self, auth: &Auth, now: i64) -> Result<Option<Vec<Device>>> {
        if !self.active(auth, now)? {
            return Ok(None);
        }
        let mut stmt = self.db.prepare("SELECT id,funti_id,pk,name,version,bound_at,last_seen FROM devices WHERE account_id=?1 ORDER BY bound_at,id")?;
        let rows = stmt.query_map([&auth.account], |r| {
            Ok(Device {
                device_id: r.get(0)?,
                funti_id: r.get(1)?,
                pk: r.get(2)?,
                name: r.get(3)?,
                version: r.get(4)?,
                bound_at: r.get(5)?,
                last_seen: r.get(6)?,
            })
        })?;
        Ok(Some(rows.collect::<rusqlite::Result<_>>()?))
    }

    pub fn family(&self, auth: &Auth, now: i64) -> Result<Option<Vec<FamilyCopy>>> {
        if !self.active(auth, now)? {
            return Ok(None);
        }
        let mut stmt = self.db.prepare("SELECT d.id,d.name,f.revision,f.updated_at,f.members_json FROM family_copies f JOIN devices d ON d.id=f.device_id WHERE d.account_id=?1 ORDER BY d.id")?;
        let rows = stmt.query_map([&auth.account], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, String>(4)?,
            ))
        })?;
        let mut copies = Vec::new();
        for row in rows {
            let (source_device_id, source_name, revision, updated_at, data) = row?;
            copies.push(FamilyCopy {
                source_device_id,
                source_name,
                revision,
                updated_at,
                members: serde_json::from_str(&data)?,
            });
        }
        Ok(Some(copies))
    }

    pub fn bind_nonce(
        &mut self,
        auth: &Auth,
        id: &str,
        pk: &str,
        ip: &str,
        now: i64,
    ) -> Result<Option<Nonce>> {
        if !crypto::valid_id(id) || crypto::public_key(pk).is_err() {
            return Ok(None);
        }
        let nonce = Nonce {
            nonce: crypto::token(),
            account_id: auth.account.clone(),
            device_id: None,
            action: "bind".to_owned(),
            funti_id: id.to_owned(),
            pk: pk.to_owned(),
            payload_hash: String::new(),
            expires_at: now + 300,
            session_hash: Some(auth.hash.clone()),
        };
        let key = self.key;
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? || !nonce_quota(&tx, &key, ip, now)? {
            tx.commit()?;
            return Ok(None);
        }
        tx.execute(
            "UPDATE nonces SET used=1 WHERE session_hash=?1 AND action='bind' AND used=0",
            [&auth.hash],
        )?;
        insert_nonce(&tx, &nonce, now)?;
        tx.commit()?;
        Ok(Some(nonce))
    }

    pub fn source_nonce(
        &mut self,
        source: &str,
        action: &str,
        hash: &str,
        auth: Option<&Auth>,
        ip: &str,
        now: i64,
    ) -> Result<Option<Nonce>> {
        if !crypto::is_token(source)
            || !crypto::is_token(hash)
            || !["family", "sync", "ack"].contains(&action)
        {
            return Ok(None);
        }
        let key = self.key;
        let tx = self.db.transaction()?;
        let device = tx
            .query_row(
                "SELECT account_id,funti_id,pk FROM devices WHERE id=?1",
                [source],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((account_id, funti_id, pk)) = device else {
            return Ok(None);
        };
        if action == "family" {
            let Some(auth) = auth else {
                return Ok(None);
            };
            if auth.account != account_id || !active_in(&tx, auth, now)? {
                return Ok(None);
            }
        }
        if !nonce_quota(&tx, &key, ip, now)? {
            tx.commit()?;
            return Ok(None);
        }
        let nonce = Nonce {
            nonce: crypto::token(),
            account_id,
            device_id: Some(source.to_owned()),
            action: action.to_owned(),
            funti_id,
            pk,
            payload_hash: hash.to_owned(),
            expires_at: now + 300,
            session_hash: auth.map(|a| a.hash.clone()),
        };
        insert_nonce(&tx, &nonce, now)?;
        tx.commit()?;
        Ok(Some(nonce))
    }

    pub fn nonce(&self, id: &str, now: i64) -> Result<Option<Nonce>> {
        if !crypto::is_token(id) {
            return Ok(None);
        }
        Ok(self.db.query_row("SELECT id,account_id,device_id,action,funti_id,pk,payload_hash,expires_at,session_hash FROM nonces WHERE id=?1 AND used=0 AND expires_at>?2", params![id,now], |r| Ok(Nonce { nonce:r.get(0)?,account_id:r.get(1)?,device_id:r.get(2)?,action:r.get(3)?,funti_id:r.get(4)?,pk:r.get(5)?,payload_hash:r.get(6)?,expires_at:r.get(7)?,session_hash:r.get(8)? })).optional()?)
    }

    pub fn bind_device(
        &mut self,
        nonce: &Nonce,
        auth: &Auth,
        name: &str,
        version: &str,
        now: i64,
    ) -> Result<Option<String>> {
        if nonce.action != "bind"
            || nonce.account_id != auth.account
            || nonce.session_hash.as_deref() != Some(&auth.hash)
            || !label(name, 256)
            || !label(version, 64)
        {
            return Ok(None);
        }
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? || !consume_nonce(&tx, nonce, now)? {
            return Ok(None);
        }
        let existing = tx
            .query_row(
                "SELECT id,account_id FROM devices WHERE pk=?1",
                [&nonce.pk],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((id, account)) = existing {
            if account != auth.account {
                return Ok(None);
            }
            tx.execute(
                "UPDATE devices SET funti_id=?2,name=?3,version=?4,last_seen=?5 WHERE id=?1",
                params![id, nonce.funti_id, name, version, now],
            )?;
            tx.commit()?;
            return Ok(Some(id));
        }
        let count: i64 = tx.query_row(
            "SELECT COUNT(*) FROM devices WHERE account_id=?1",
            [&auth.account],
            |r| r.get(0),
        )?;
        if count >= MAX_DEVICES {
            return Ok(None);
        }
        let id = crypto::token();
        tx.execute("INSERT INTO devices(id,account_id,funti_id,pk,name,version,bound_at,last_seen) VALUES(?1,?2,?3,?4,?5,?6,?7,?7)", params![id,auth.account,nonce.funti_id,nonce.pk,name,version,now])?;
        // A newly bound source also receives earlier removals. A stale local
        // family must not silently bypass a removal merely by joining later.
        tx.execute("INSERT INTO deliveries(event_id,device_id) SELECT id,?1 FROM events WHERE account_id=?2 AND kind='remove'", params![id,auth.account])?;
        tx.commit()?;
        Ok(Some(id))
    }

    pub fn save_family(
        &mut self,
        nonce: &Nonce,
        auth: &Auth,
        payload: &FamilyPayload,
        now: i64,
    ) -> Result<bool> {
        if nonce.action != "family"
            || nonce.account_id != auth.account
            || nonce.session_hash.as_deref() != Some(&auth.hash)
            || !family_valid(payload)
            || payload_hash(payload)? != nonce.payload_hash
        {
            return Ok(false);
        }
        let Some(source) = nonce.device_id.as_deref() else {
            return Ok(false);
        };
        let data = serde_json::to_string(&payload.members)?;
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? || !consume_nonce(&tx, nonce, now)? {
            return Ok(false);
        }
        tx.execute("INSERT INTO family_copies(device_id,revision,members_json,updated_at) VALUES(?1,1,?2,?3) ON CONFLICT(device_id) DO UPDATE SET revision=family_copies.revision+CASE WHEN family_copies.members_json=excluded.members_json THEN 0 ELSE 1 END,members_json=excluded.members_json,updated_at=excluded.updated_at", params![source,data,now])?;
        tx.execute(
            "UPDATE devices SET name=?2,version=?3,last_seen=?4 WHERE id=?1",
            params![source, payload.name, payload.version, now],
        )?;
        tx.commit()?;
        Ok(true)
    }

    pub fn remove_member(
        &mut self,
        auth: &Auth,
        pk: &str,
        request_id: &str,
        now: i64,
    ) -> Result<Option<i64>> {
        if crypto::public_key(pk).is_err() || !crypto::is_token(request_id) {
            return Ok(None);
        }
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? {
            return Ok(None);
        }
        let existing = tx
            .query_row(
                "SELECT id,target_pk FROM events WHERE account_id=?1 AND request_id=?2",
                params![auth.account, request_id],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((id, target)) = existing {
            return Ok((target == pk).then_some(id));
        }
        let known: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM devices WHERE account_id=?1 AND pk=?2)",
            params![auth.account, pk],
            |r| r.get(0),
        )?;
        if !known {
            let mut stmt = tx.prepare("SELECT f.members_json FROM family_copies f JOIN devices d ON d.id=f.device_id WHERE d.account_id=?1")?;
            let rows = stmt.query_map([&auth.account], |r| r.get::<_, String>(0))?;
            let mut found = false;
            for row in rows {
                if serde_json::from_str::<Vec<FamilyMember>>(&row?)?
                    .iter()
                    .any(|m| m.pk == pk)
                {
                    found = true;
                }
            }
            if !found {
                return Ok(None);
            }
        }
        if !quotas(&tx, now, &[(&format!("remove:{}", auth.account), 60, 30)])? {
            tx.commit()?;
            return Ok(None);
        }
        let id = new_event(&tx, &auth.account, "remove", pk, now)?;
        tx.execute(
            "UPDATE events SET request_id=?2 WHERE id=?1",
            params![id, request_id],
        )?;
        tx.commit()?;
        Ok(Some(id))
    }

    pub fn sync(
        &mut self,
        nonce: &Nonce,
        payload: &SyncPayload,
        now: i64,
    ) -> Result<Option<Value>> {
        if nonce.action != "sync"
            || payload.after < 0
            || payload_hash(payload)? != nonce.payload_hash
        {
            return Ok(None);
        }
        let Some(source) = nonce.device_id.as_deref() else {
            return Ok(None);
        };
        let tx = self.db.transaction()?;
        if !consume_nonce(&tx, nonce, now)? {
            return Ok(None);
        }
        let mut events = Vec::new();
        {
            let mut stmt = tx.prepare("SELECT e.id,e.kind,e.target_pk,e.created_at FROM events e JOIN deliveries d ON d.event_id=e.id WHERE d.device_id=?1 AND e.id>?2 ORDER BY e.id LIMIT 128")?;
            let rows = stmt.query_map(params![source,payload.after], |r| Ok(json!({"event_id":r.get::<_,i64>(0)?,"kind":r.get::<_,String>(1)?,"target_pk":r.get::<_,String>(2)?,"created_at":r.get::<_,i64>(3)?})))?;
            for row in rows {
                events.push(row?);
            }
        }
        tx.execute(
            "UPDATE devices SET last_seen=?2 WHERE id=?1",
            params![source, now],
        )?;
        tx.commit()?;
        // Client's durable cursor, rather than server acknowledgement, controls
        // replay. A restored client can therefore fetch previously acked events.
        Ok(Some(json!({"events":events})))
    }

    pub fn acknowledge(&mut self, nonce: &Nonce, payload: &AckPayload, now: i64) -> Result<bool> {
        if nonce.action != "ack"
            || payload_hash(payload)? != nonce.payload_hash
            || payload.events.is_empty()
            || payload.events.len() > 128
        {
            return Ok(false);
        }
        if payload.events.iter().any(|id| *id <= 0)
            || payload
                .events
                .iter()
                .collect::<std::collections::HashSet<_>>()
                .len()
                != payload.events.len()
        {
            return Ok(false);
        }
        let Some(source) = nonce.device_id.as_deref() else {
            return Ok(false);
        };
        let tx = self.db.transaction()?;
        if !consume_nonce(&tx, nonce, now)? {
            return Ok(false);
        }
        for id in &payload.events {
            let count = tx.execute("UPDATE deliveries SET acknowledged_at=COALESCE(acknowledged_at,?3) WHERE event_id=?1 AND device_id=?2", params![id,source,now])?;
            if count != 1 {
                return Ok(false);
            }
        }
        tx.commit()?;
        Ok(true)
    }

    pub fn removals(&self, auth: &Auth, now: i64) -> Result<Option<Value>> {
        if !self.active(auth, now)? {
            return Ok(None);
        }
        let mut stmt = self.db.prepare("SELECT e.id,e.target_pk,e.created_at,d.device_id,d.acknowledged_at FROM events e JOIN deliveries d ON d.event_id=e.id WHERE e.account_id=?1 AND e.kind='remove' ORDER BY e.id DESC,d.device_id LIMIT 4097")?;
        let rows = stmt.query_map([&auth.account], |r| Ok(json!({"event_id":r.get::<_,i64>(0)?,"target_pk":r.get::<_,String>(1)?,"created_at":r.get::<_,i64>(2)?,"source_device_id":r.get::<_,String>(3)?,"acknowledged_at":r.get::<_,Option<i64>>(4)?})))?;
        let mut deliveries = rows.collect::<rusqlite::Result<Vec<_>>>()?;
        let has_more = deliveries.len() > 4096;
        deliveries.truncate(4096);
        Ok(Some(json!({"deliveries":deliveries,"has_more":has_more})))
    }
}

fn nonce_quota(tx: &Transaction<'_>, key: &[u8; 32], ip: &str, now: i64) -> Result<bool> {
    let ip = crypto::tag(key, "ip-index", &[ip]);
    quotas(
        tx,
        now,
        &[
            ("nonce:global", 60, 600),
            (&format!("nonce:ip:{ip}"), 60, 240),
        ],
    )
}

fn insert_nonce(tx: &Transaction<'_>, nonce: &Nonce, now: i64) -> Result<()> {
    tx.execute("DELETE FROM nonces WHERE expires_at<=?1", [now])?;
    tx.execute("INSERT INTO nonces(id,account_id,device_id,session_hash,action,funti_id,pk,payload_hash,expires_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",params![nonce.nonce,nonce.account_id,nonce.device_id,nonce.session_hash,nonce.action,nonce.funti_id,nonce.pk,nonce.payload_hash,nonce.expires_at])?;
    Ok(())
}

fn consume_nonce(tx: &Transaction<'_>, nonce: &Nonce, now: i64) -> Result<bool> {
    Ok(tx.execute(
        "UPDATE nonces SET used=1 WHERE id=?1 AND used=0 AND expires_at>?2",
        params![nonce.nonce, now],
    )? == 1)
}

pub fn routes() -> Router<App> {
    Router::new()
        .route("/devices", get(list_devices))
        .route("/family", get(list_family))
        .route("/devices/bind/nonce", post(bind_nonce))
        .route("/devices/bind", post(bind))
        .route("/devices/{id}/family/nonce", post(family_nonce))
        .route("/devices/{id}/family", post(upload_family))
        .route("/devices/{id}/sync/nonce", post(sync_nonce))
        .route("/devices/{id}/sync", post(sync))
        .route("/devices/{id}/ack/nonce", post(ack_nonce))
        .route("/devices/{id}/ack", post(ack))
        .route("/family/remove", post(remove))
        .route("/family/removals", get(removals))
}

async fn list_devices(State(app): State<App>, headers: HeaderMap) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, false).await?;
    let now = app.now();
    let devices = app
        .db(move |db| db.devices(&auth, now))
        .await?
        .ok_or_else(web::invalid)?;
    Ok(Json(json!({"devices":devices})))
}
async fn list_family(State(app): State<App>, headers: HeaderMap) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, false).await?;
    let now = app.now();
    let family = app
        .db(move |db| db.family(&auth, now))
        .await?
        .ok_or_else(web::invalid)?;
    Ok(Json(json!({"sources":family})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BindNonce {
    funti_id: String,
    pk: String,
}
async fn bind_nonce(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(input): Json<BindNonce>,
) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let ip = web::ip(&app, &headers, peer);
    let now = app.now();
    let nonce = app
        .db(move |db| db.bind_nonce(&auth, &input.funti_id, &input.pk, &ip, now))
        .await?
        .ok_or_else(web::invalid)?;
    Ok(Json(
        serde_json::to_value(nonce).map_err(|_| web::invalid())?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bind {
    nonce: String,
    signature: String,
    name: String,
    version: String,
}
async fn bind(
    State(app): State<App>,
    headers: HeaderMap,
    Json(input): Json<Bind>,
) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let nonce = proof_nonce(&app, &input.nonce, &input.signature, "bind", None).await?;
    let registered = app
        .registry
        .key(&nonce.funti_id)
        .await?
        .ok_or_else(web::invalid)?;
    if registered != crypto::public_key(&nonce.pk).map_err(|_| web::invalid())? {
        return Err(web::invalid());
    }
    let now = app.now();
    let id = app
        .db(move |db| db.bind_device(&nonce, &auth, &input.name, &input.version, now))
        .await?
        .ok_or_else(web::invalid)?;
    Ok(Json(json!({"device_id":id})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HashRequest {
    payload_hash: String,
}
async fn family_nonce(
    State(app): State<App>,
    Path(id): Path<String>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(input): Json<HashRequest>,
) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, true).await?;
    source_nonce(app, id, peer, headers, input, "family", Some(auth)).await
}
async fn sync_nonce(
    State(app): State<App>,
    Path(id): Path<String>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(input): Json<HashRequest>,
) -> ApiResult<Json<Value>> {
    source_nonce(app, id, peer, headers, input, "sync", None).await
}
async fn ack_nonce(
    State(app): State<App>,
    Path(id): Path<String>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(input): Json<HashRequest>,
) -> ApiResult<Json<Value>> {
    source_nonce(app, id, peer, headers, input, "ack", None).await
}
async fn source_nonce(
    app: App,
    id: String,
    peer: SocketAddr,
    headers: HeaderMap,
    input: HashRequest,
    action: &'static str,
    auth: Option<Auth>,
) -> ApiResult<Json<Value>> {
    let ip = web::ip(&app, &headers, peer);
    let now = app.now();
    let nonce = app
        .db(move |db| db.source_nonce(&id, action, &input.payload_hash, auth.as_ref(), &ip, now))
        .await?
        .ok_or_else(web::invalid)?;
    Ok(Json(
        serde_json::to_value(nonce).map_err(|_| web::invalid())?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Signed<T> {
    nonce: String,
    signature: String,
    payload: T,
}
async fn proof_nonce(
    app: &App,
    id: &str,
    sig: &str,
    action: &str,
    source: Option<&str>,
) -> ApiResult<Nonce> {
    let now = app.now();
    let id = id.to_owned();
    let nonce = app
        .db(move |db| db.nonce(&id, now))
        .await?
        .ok_or_else(web::invalid)?;
    if nonce.action != action
        || (source.is_some() && nonce.device_id.as_deref() != source)
        || !crypto::signature(&nonce.pk, &nonce.message(), sig)
    {
        return Err(web::invalid());
    }
    Ok(nonce)
}
async fn upload_family(
    State(app): State<App>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Signed<FamilyPayload>>,
) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let nonce = proof_nonce(&app, &input.nonce, &input.signature, "family", Some(&id)).await?;
    let now = app.now();
    if !app
        .db(move |db| db.save_family(&nonce, &auth, &input.payload, now))
        .await?
    {
        return Err(web::invalid());
    }
    Ok(Json(json!({"saved":true})))
}
async fn sync(
    State(app): State<App>,
    Path(id): Path<String>,
    Json(input): Json<Signed<SyncPayload>>,
) -> ApiResult<Json<Value>> {
    let nonce = proof_nonce(&app, &input.nonce, &input.signature, "sync", Some(&id)).await?;
    let now = app.now();
    Ok(Json(
        app.db(move |db| db.sync(&nonce, &input.payload, now))
            .await?
            .ok_or_else(web::invalid)?,
    ))
}
async fn ack(
    State(app): State<App>,
    Path(id): Path<String>,
    Json(input): Json<Signed<AckPayload>>,
) -> ApiResult<Json<Value>> {
    let nonce = proof_nonce(&app, &input.nonce, &input.signature, "ack", Some(&id)).await?;
    let now = app.now();
    if !app
        .db(move |db| db.acknowledge(&nonce, &input.payload, now))
        .await?
    {
        return Err(web::invalid());
    }
    Ok(Json(json!({"acknowledged":true})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Remove {
    target_pk: String,
    request_id: String,
}
async fn remove(
    State(app): State<App>,
    headers: HeaderMap,
    Json(input): Json<Remove>,
) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let now = app.now();
    let id = app
        .db(move |db| db.remove_member(&auth, &input.target_pk, &input.request_id, now))
        .await?
        .ok_or_else(web::invalid)?;
    Ok(Json(json!({"event_id":id,"status":"pending"})))
}
async fn removals(State(app): State<App>, headers: HeaderMap) -> ApiResult<Json<Value>> {
    let auth = web::authorize(&app, &headers, false).await?;
    let now = app.now();
    Ok(Json(
        app.db(move |db| db.removals(&auth, now))
            .await?
            .ok_or_else(web::invalid)?,
    ))
}
