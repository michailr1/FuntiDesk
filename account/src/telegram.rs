//! Browser-bound, one-use challenges approved only by the trusted bot bridge.
use crate::{
    config::{LOGIN_COOKIE, SESSION_COOKIE, SESSION_TTL},
    crypto,
    store::{active_in, new_event, quotas, Auth, Issued, Store, TooManySessions},
    web::{self, ApiError, ApiResult},
    App,
};
use anyhow::{bail, Result};
use axum::{
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use rusqlite::{params, OptionalExtension};
use serde::Deserialize;
use serde_json::json;
use std::net::SocketAddr;

pub fn routes() -> Router<App> {
    Router::new()
        .route("/auth/telegram/start", post(start))
        .route("/auth/telegram/status", post(status))
        .route("/auth/telegram/finish", post(finish))
        .route("/auth/telegram/link", post(link))
        .route("/auth/telegram/unlink", post(unlink))
        .route("/auth/telegram/approve", post(approve))
}
fn reject() -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, "invalid_telegram_challenge")
}
fn enabled(app: &App) -> ApiResult<()> {
    if app.telegram_bridge.is_some() {
        Ok(())
    } else {
        Err(ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "telegram_unavailable",
        ))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RequestId {
    id: String,
    #[serde(default)]
    linking: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Approval {
    code: String,
    telegram_id: i64,
}
fn db_error(error: anyhow::Error) -> ApiError {
    if error.is::<TooManySessions>() {
        ApiError(StatusCode::TOO_MANY_REQUESTS, "too_many_sessions")
    } else {
        error.into()
    }
}
async fn binding(
    app: &App,
    headers: &HeaderMap,
    linking: bool,
) -> ApiResult<(String, Option<Auth>)> {
    if headers.contains_key("x-funti-client") {
        return Err(reject());
    }
    if linking {
        let auth = web::authorize(app, headers, true).await?;
        Ok((
            crypto::tag(&app.key, "telegram-link", &[&auth.hash]),
            Some(auth),
        ))
    } else {
        let (scope, browser) = web::login_context(app, headers)?;
        if !browser {
            return Err(reject());
        }
        Ok((crypto::tag(&app.key, "telegram-login", &[&scope]), None))
    }
}
async fn begin(
    app: App,
    headers: HeaderMap,
    peer: SocketAddr,
    linking: bool,
) -> ApiResult<Response> {
    enabled(&app)?;
    let (scope, auth) = binding(&app, &headers, linking).await?;
    let ip = web::ip(&app, &headers, peer);
    let now = app.now();
    let code = crypto::token()[..10].to_uppercase();
    let display = format!("{}-{}", &code[..5], &code[5..]);
    let result = app
        .db(move |db| db.telegram_begin(&scope, auth.as_ref(), &ip, &code, now))
        .await?;
    let Some(id) = result else {
        return Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "try_later"));
    };
    Ok(Json(json!({"id":id,"code":display,"expires_in":300,"bot_url":"https://t.me/funtidesk_bot?start=login"})).into_response())
}
async fn start(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    begin(app, headers, peer, false).await
}
async fn link(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    begin(app, headers, peer, true).await
}
async fn status(
    State(app): State<App>,
    headers: HeaderMap,
    Json(input): Json<RequestId>,
) -> ApiResult<Json<serde_json::Value>> {
    enabled(&app)?;
    if !crypto::is_token(&input.id) {
        return Err(reject());
    }
    let (scope, _) = binding(&app, &headers, input.linking).await?;
    let now = app.now();
    let value = app
        .db(move |db| db.telegram_status(&input.id, &scope, now))
        .await?;
    Ok(Json(json!({"status":value})))
}
async fn finish(
    State(app): State<App>,
    headers: HeaderMap,
    Json(input): Json<RequestId>,
) -> ApiResult<Response> {
    enabled(&app)?;
    if !crypto::is_token(&input.id) {
        return Err(reject());
    }
    let (scope, auth) = binding(&app, &headers, input.linking).await?;
    let old = web::cookie(&headers, SESSION_COOKIE).map(|raw| crypto::digest(raw.as_bytes()));
    let now = app.now();
    let issued = app
        .db(move |db| db.telegram_finish(&input.id, &scope, auth.as_ref(), old.as_deref(), now))
        .await
        .map_err(db_error)?
        .ok_or_else(reject)?;
    let mut response=Json(json!({"account_id":issued.account,"csrf":crypto::tag(&app.key,"session-csrf",&[&issued.token])})).into_response();
    web::set_cookie(&mut response, SESSION_COOKIE, &issued.token, SESSION_TTL)?;
    web::set_cookie(&mut response, LOGIN_COOKIE, "", 0)?;
    Ok(response)
}
async fn unlink(State(app): State<App>, headers: HeaderMap) -> ApiResult<Response> {
    enabled(&app)?;
    if headers.contains_key("x-funti-client") {
        return Err(reject());
    }
    let auth = web::authorize(&app, &headers, true).await?;
    let now = app.now();
    if !app.db(move |db| db.telegram_unlink(&auth, now)).await? {
        return Err(ApiError(StatusCode::CONFLICT, "email_required"));
    }
    let mut response = StatusCode::NO_CONTENT.into_response();
    web::set_cookie(&mut response, SESSION_COOKIE, "", 0)?;
    Ok(response)
}
async fn approve(
    State(app): State<App>,
    headers: HeaderMap,
    Json(input): Json<Approval>,
) -> ApiResult<Json<serde_json::Value>> {
    enabled(&app)?;
    // This endpoint is server-to-server only. Browser/session credentials are not accepted.
    if headers.contains_key("origin")
        || headers.contains_key("cookie")
        || headers.contains_key("x-funti-client")
    {
        return Err(reject());
    }
    let expected = hex::encode(app.telegram_bridge.ok_or_else(reject)?);
    let provided = web::text(&headers, "authorization")
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(reject)?;
    if !crypto::is_token(provided)
        || !crypto::matches(
            &app.key,
            "telegram-bridge",
            &[provided],
            &crypto::tag(&app.key, "telegram-bridge", &[&expected]),
        )
    {
        return Err(ApiError(StatusCode::FORBIDDEN, "request_rejected"));
    }
    let code = input.code.replace('-', "").to_uppercase();
    if code.len() != 10 || !code.bytes().all(|c| c.is_ascii_hexdigit()) || input.telegram_id <= 0 {
        return Err(reject());
    }
    let now = app.now();
    let approved = app
        .db(move |db| db.telegram_approve(&code, input.telegram_id, now))
        .await?;
    Ok(Json(json!({"approved":approved})))
}
impl Store {
    pub fn telegram_begin(
        &mut self,
        scope: &str,
        auth: Option<&Auth>,
        ip: &str,
        code: &str,
        now: i64,
    ) -> Result<Option<String>> {
        let tx = self.db.transaction()?;
        if let Some(auth) = auth {
            if !active_in(&tx, auth, now)? {
                return Ok(None);
            }
        }
        let ip = crypto::tag(&self.key, "telegram-ip", &[ip]);
        if !quotas(
            &tx,
            now,
            &[
                (&format!("tg-start:{ip}"), 60, 5),
                (&format!("tg-start:{ip}"), 3600, 30),
                (&format!("tg-scope:{scope}"), 300, 3),
            ],
        )? {
            tx.commit()?;
            return Ok(None);
        }
        let count: i64 = tx.query_row(
            "SELECT count(*) FROM telegram_challenges WHERE expires_at>?1 AND consumed=0",
            [now],
            |r| r.get(0),
        )?;
        if count >= 1000 {
            tx.commit()?;
            return Ok(None);
        }
        tx.execute(
            "UPDATE telegram_challenges SET consumed=1 WHERE scope_hash=?1",
            [scope],
        )?;
        let id = crypto::token();
        let hash = crypto::tag(&self.key, "telegram-code", &[code]);
        tx.execute("INSERT INTO telegram_challenges(id,scope_hash,code_hash,target_account,session_hash,expires_at) VALUES(?1,?2,?3,?4,?5,?6)",params![id,scope,hash,auth.map(|a|&a.account),auth.map(|a|&a.hash),now+300])?;
        tx.commit()?;
        Ok(Some(id))
    }
    pub fn telegram_status(&self, id: &str, scope: &str, now: i64) -> Result<&'static str> {
        let state:Option<(i64,i64,Option<String>)>=self.db.query_row("SELECT expires_at,consumed,subject_hash FROM telegram_challenges WHERE id=?1 AND scope_hash=?2",params![id,scope],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
        Ok(match state {
            Some((expiry, 0, subject)) if expiry > now => {
                if subject.is_some() {
                    "approved"
                } else {
                    "pending"
                }
            }
            _ => "expired",
        })
    }
    pub fn telegram_approve(&mut self, code: &str, subject: i64, now: i64) -> Result<bool> {
        if subject <= 0 {
            return Ok(false);
        }
        let tx = self.db.transaction()?;
        let identity = crypto::tag(&self.key, "telegram-subject", &[&subject.to_string()]);
        if !quotas(
            &tx,
            now,
            &[
                (&format!("tg-approve:{identity}"), 60, 5),
                (&format!("tg-approve:{identity}"), 3600, 20),
            ],
        )? {
            tx.commit()?;
            return Ok(false);
        }
        let hash = crypto::tag(&self.key, "telegram-code", &[code]);
        let count=tx.execute("UPDATE telegram_challenges SET subject_hash=?1 WHERE code_hash=?2 AND expires_at>?3 AND consumed=0 AND subject_hash IS NULL",params![identity,hash,now])?;
        tx.commit()?;
        Ok(count == 1)
    }
    pub fn telegram_finish(
        &mut self,
        id: &str,
        scope: &str,
        auth: Option<&Auth>,
        previous: Option<&str>,
        now: i64,
    ) -> Result<Option<Issued>> {
        let tx = self.db.transaction()?;
        let row:Option<(String,Option<String>,Option<String>)>=tx.query_row("SELECT subject_hash,target_account,session_hash FROM telegram_challenges WHERE id=?1 AND scope_hash=?2 AND expires_at>?3 AND consumed=0 AND subject_hash IS NOT NULL",params![id,scope,now],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
        let Some((subject, target, session)) = row else {
            return Ok(None);
        };
        if target.is_some()
            && !auth.is_some_and(|a| {
                Some(&a.account) == target.as_ref()
                    && Some(&a.hash) == session.as_ref()
                    && active_in(&tx, a, now).unwrap_or(false)
            })
        {
            return Ok(None);
        }
        if target.is_none() && auth.is_some() {
            return Ok(None);
        }
        let existing: Option<String> = tx
            .query_row(
                "SELECT account_id FROM telegram_identities WHERE subject_hash=?1",
                [&subject],
                |r| r.get(0),
            )
            .optional()?;
        if let (Some(target), Some(existing)) = (&target, &existing) {
            if target != existing {
                return Ok(None);
            }
        }
        let account = match target.or(existing) {
            Some(value) => value,
            None => {
                let value = crypto::token();
                tx.execute(
                    "INSERT INTO accounts(id,email,created_at) VALUES(?1,NULL,?2)",
                    params![value, now],
                )?;
                value
            }
        };
        let active: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND disabled=0)",
            [&account],
            |r| r.get(0),
        )?;
        if !active {
            return Ok(None);
        }
        let linked: Option<String> = tx
            .query_row(
                "SELECT subject_hash FROM telegram_identities WHERE account_id=?1",
                [&account],
                |r| r.get(0),
            )
            .optional()?;
        if linked.as_ref().is_some_and(|value| value != &subject) {
            return Ok(None);
        }
        let count:i64=tx.query_row("SELECT count(*) FROM sessions WHERE account_id=?1 AND revoked_at IS NULL AND expires_at>?2 AND NOT(token_hash=?3 AND browser=1)",params![account,now,previous.unwrap_or("")],|r|r.get(0))?;
        if count >= 20 {
            bail!(TooManySessions);
        }
        tx.execute("INSERT INTO telegram_identities(subject_hash,account_id,linked_at) VALUES(?1,?2,?3) ON CONFLICT(subject_hash) DO NOTHING",params![subject,account,now])?;
        tx.execute(
            "UPDATE telegram_challenges SET consumed=1 WHERE id=?1",
            [id],
        )?;
        if let Some(previous) = previous {
            tx.execute(
                "UPDATE sessions SET revoked_at=?2 WHERE token_hash=?1 AND browser=1",
                params![previous, now],
            )?;
        }
        let token = crypto::token();
        tx.execute("INSERT INTO sessions(token_hash,account_id,browser,created_at,expires_at) VALUES(?1,?2,1,?3,?4)",params![crypto::digest(token.as_bytes()),account,now,now+SESSION_TTL])?;
        new_event(&tx, &account, "login", "", now)?;
        tx.commit()?;
        Ok(Some(Issued { token, account }))
    }
    pub fn telegram_unlink(&mut self, auth: &Auth, now: i64) -> Result<bool> {
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? {
            return Ok(false);
        }
        let email: Option<String> = tx.query_row(
            "SELECT email FROM accounts WHERE id=?1",
            [&auth.account],
            |r| r.get(0),
        )?;
        if email.is_none() {
            return Ok(false);
        }
        let subject: Option<String> = tx
            .query_row(
                "SELECT subject_hash FROM telegram_identities WHERE account_id=?1",
                [&auth.account],
                |r| r.get(0),
            )
            .optional()?;
        let Some(subject) = subject else {
            return Ok(false);
        };
        tx.execute(
            "DELETE FROM telegram_identities WHERE account_id=?1",
            [&auth.account],
        )?;
        tx.execute(
            "UPDATE sessions SET revoked_at=?2 WHERE account_id=?1",
            params![auth.account, now],
        )?;
        tx.execute(
            "UPDATE telegram_challenges SET consumed=1 WHERE target_account=?1 OR subject_hash=?2",
            params![auth.account, subject],
        )?;
        tx.commit()?;
        Ok(true)
    }
}
