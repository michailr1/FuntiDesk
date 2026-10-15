use crate::{
    config::{self, LOGIN_COOKIE, SESSION_COOKIE},
    crypto, devices, library, mail,
    store::{Auth, SessionRequest},
    App,
};
use axum::{
    extract::{ConnectInfo, DefaultBodyLimit, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::net::SocketAddr;

pub(crate) struct ApiError(pub StatusCode, pub &'static str);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}
impl From<anyhow::Error> for ApiError {
    fn from(_: anyhow::Error) -> Self {
        Self(StatusCode::SERVICE_UNAVAILABLE, "service_unavailable")
    }
}
pub(crate) type ApiResult<T> = Result<T, ApiError>;
pub(crate) fn invalid() -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, "invalid_request")
}
fn unauthenticated() -> ApiError {
    ApiError(StatusCode::UNAUTHORIZED, "authentication_required")
}
fn forbidden() -> ApiError {
    ApiError(StatusCode::FORBIDDEN, "request_rejected")
}

pub fn router(app: App) -> Router {
    let api = Router::new()
        .route("/auth/bootstrap", get(bootstrap))
        .route("/auth/request", post(request_code))
        .route("/auth/verify", post(verify_code))
        .route("/session", get(session))
        .route("/logout", post(logout))
        .route("/logout-all", post(logout_all))
        .merge(devices::routes())
        .merge(library::routes())
        .layer(DefaultBodyLimit::max(64 * 1024))
        .layer(middleware::from_fn_with_state(app.clone(), perimeter));
    Router::new()
        .route("/health", get(|| async { "ok" }))
        .nest(config::API, api)
        .with_state(app)
}

async fn perimeter(State(app): State<App>, request: Request, next: Next) -> Response {
    if app.now() <= 0 {
        return ApiError(StatusCode::SERVICE_UNAVAILABLE, "service_unavailable").into_response();
    }
    let Ok(_permit) = app.permits.try_acquire() else {
        return ApiError(StatusCode::SERVICE_UNAVAILABLE, "try_later").into_response();
    };
    let host = text(request.headers(), "host");
    if host != Some("desk.funti.cc") && host != Some("desk.funti.cc:443") {
        return forbidden().into_response();
    }
    if request.headers().contains_key("origin")
        && text(request.headers(), "origin") != Some(config::ORIGIN)
    {
        return forbidden().into_response();
    }
    let mut response =
        match tokio::time::timeout(std::time::Duration::from_secs(20), next.run(request)).await {
            Ok(response) => response,
            Err(_) => {
                return ApiError(StatusCode::SERVICE_UNAVAILABLE, "try_later").into_response()
            }
        };
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

pub(crate) fn text<'a>(headers: &'a HeaderMap, key: &str) -> Option<&'a str> {
    if headers.get_all(key).iter().count() != 1 {
        return None;
    }
    headers.get(key)?.to_str().ok()
}

fn cookie(headers: &HeaderMap, name: &str) -> Option<String> {
    let values: Vec<_> = headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|value| value.split(';'))
        .filter_map(|part| part.trim().split_once('='))
        .filter(|(key, _)| *key == name)
        .map(|(_, value)| value.to_owned())
        .collect();
    if values.len() == 1 && crypto::is_token(&values[0]) {
        values.into_iter().next()
    } else {
        None
    }
}

fn native(headers: &HeaderMap) -> ApiResult<bool> {
    match text(headers, "x-funti-client") {
        None => Ok(false),
        Some("native") if !headers.contains_key(header::COOKIE) => Ok(true),
        _ => Err(forbidden()),
    }
}

pub(crate) fn ip(app: &App, headers: &HeaderMap, peer: SocketAddr) -> String {
    if app.proxies.contains(&peer.ip()) {
        if let Some(value) = text(headers, "x-funti-client-ip") {
            if let Ok(ip) = value.parse::<std::net::IpAddr>() {
                return ip.to_string();
            }
        }
    }
    peer.ip().to_string()
}

fn login_context(app: &App, headers: &HeaderMap) -> ApiResult<(String, bool)> {
    if native(headers)? {
        let scope = text(headers, "x-funti-login")
            .filter(|s| crypto::is_token(s))
            .ok_or_else(forbidden)?;
        return Ok((scope.to_owned(), false));
    }
    if text(headers, "origin") != Some(config::ORIGIN) {
        return Err(forbidden());
    }
    let scope = cookie(headers, LOGIN_COOKIE).ok_or_else(forbidden)?;
    let csrf = text(headers, "x-funti-csrf").ok_or_else(forbidden)?;
    if !crypto::matches(&app.key, "login-csrf", &[&scope], csrf) {
        return Err(forbidden());
    }
    Ok((scope, true))
}

pub(crate) async fn authorize(app: &App, headers: &HeaderMap, change: bool) -> ApiResult<Auth> {
    let is_native = native(headers)?;
    let raw = if is_native {
        text(headers, "authorization")
            .and_then(|value| value.strip_prefix("Bearer "))
            .map(str::to_owned)
    } else {
        if headers.contains_key(header::AUTHORIZATION) {
            return Err(forbidden());
        }
        cookie(headers, SESSION_COOKIE)
    }
    .ok_or_else(unauthenticated)?;
    if !is_native && change {
        if text(headers, "origin") != Some(config::ORIGIN) {
            return Err(forbidden());
        }
        let csrf = text(headers, "x-funti-csrf").ok_or_else(forbidden)?;
        if !crypto::matches(&app.key, "session-csrf", &[&raw], csrf) {
            return Err(forbidden());
        }
    }
    let now = app.now();
    app.db(move |db| db.authenticate(&raw, !is_native, now))
        .await?
        .ok_or_else(unauthenticated)
}

fn set_cookie(response: &mut Response, name: &str, value: &str, max_age: i64) -> ApiResult<()> {
    let cookie = HeaderValue::from_str(&format!(
        "{name}={value}; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age={max_age}"
    ))
    .map_err(|_| invalid())?;
    response.headers_mut().append(header::SET_COOKIE, cookie);
    Ok(())
}

async fn bootstrap(State(app): State<App>, headers: HeaderMap) -> ApiResult<Response> {
    let is_native = native(&headers)?;
    let scope = if is_native {
        crypto::token()
    } else {
        cookie(&headers, LOGIN_COOKIE).unwrap_or_else(crypto::token)
    };
    let csrf = crypto::tag(&app.key, "login-csrf", &[&scope]);
    let mut response = Json(if is_native {
        json!({"login_context":scope})
    } else {
        json!({"csrf":csrf})
    })
    .into_response();
    if !is_native {
        set_cookie(&mut response, LOGIN_COOKIE, &scope, 3600)?;
    }
    Ok(response)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CodeRequest {
    email: String,
}
async fn request_code(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(input): Json<CodeRequest>,
) -> ApiResult<Response> {
    let (scope, _) = login_context(&app, &headers)?;
    let email = mail::normalize_email(&input.email).ok_or_else(invalid)?;
    let ip = ip(&app, &headers, peer);
    let code = crypto::code();
    let now = app.now();
    let (saved_email, saved_code) = (email.clone(), code.clone());
    let id = app
        .db(move |db| db.begin_login(&saved_email, &scope, &ip, &saved_code, now))
        .await?
        .ok_or(ApiError(StatusCode::TOO_MANY_REQUESTS, "try_later"))?;
    if app
        .mail
        .try_send(mail::MailJob {
            challenge: id.clone(),
            email,
            code,
        })
        .is_err()
    {
        let cancelled = id.clone();
        app.db(move |db| db.cancel_challenge(&cancelled)).await?;
        return Err(ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "service_unavailable",
        ));
    }
    Ok((
        StatusCode::ACCEPTED,
        Json(json!({"challenge_id":id,"expires_in":config::CODE_TTL})),
    )
        .into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CodeVerify {
    challenge_id: String,
    code: String,
}
async fn verify_code(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(input): Json<CodeVerify>,
) -> ApiResult<Response> {
    let (scope, browser) = login_context(&app, &headers)?;
    let ip = ip(&app, &headers, peer);
    let old_hash = cookie(&headers, SESSION_COOKIE).map(|raw| crypto::digest(raw.as_bytes()));
    let now = app.now();
    let issued = app
        .db(move |db| {
            db.verify_login(
                &input.challenge_id,
                &scope,
                &input.code,
                &ip,
                if browser {
                    SessionRequest::Browser {
                        previous_hash: old_hash.as_deref(),
                    }
                } else {
                    SessionRequest::Native
                },
                now,
            )
        })
        .await?
        .ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid_code"))?;
    let mut response = if browser {
        Json(json!({"account_id":issued.account,"csrf":crypto::tag(&app.key,"session-csrf",&[&issued.token])})).into_response()
    } else {
        Json(json!({"account_id":issued.account,"token":issued.token})).into_response()
    };
    if browser {
        set_cookie(
            &mut response,
            SESSION_COOKIE,
            &issued.token,
            config::SESSION_TTL,
        )?;
        set_cookie(&mut response, LOGIN_COOKIE, "", 0)?;
    }
    Ok(response)
}

async fn session(State(app): State<App>, headers: HeaderMap) -> ApiResult<Json<Value>> {
    let auth = authorize(&app, &headers, false).await?;
    let now = app.now();
    let info = app
        .db(move |db| db.session(&auth, now))
        .await?
        .ok_or_else(unauthenticated)?;
    let mut value = serde_json::to_value(info).map_err(|_| invalid())?;
    if !native(&headers)? {
        let raw = cookie(&headers, SESSION_COOKIE).ok_or_else(unauthenticated)?;
        value["csrf"] = crypto::tag(&app.key, "session-csrf", &[&raw]).into();
    }
    Ok(Json(value))
}

async fn logout(State(app): State<App>, headers: HeaderMap) -> ApiResult<Response> {
    end_session(app, headers, false).await
}
async fn logout_all(State(app): State<App>, headers: HeaderMap) -> ApiResult<Response> {
    end_session(app, headers, true).await
}
async fn end_session(app: App, headers: HeaderMap, all: bool) -> ApiResult<Response> {
    let auth = authorize(&app, &headers, true).await?;
    let browser = auth.browser;
    let now = app.now();
    if !app.db(move |db| db.logout(&auth, all, now)).await? {
        return Err(unauthenticated());
    }
    let mut response = StatusCode::NO_CONTENT.into_response();
    if browser {
        set_cookie(&mut response, SESSION_COOKIE, "", 0)?;
    }
    Ok(response)
}
