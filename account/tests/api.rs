use anyhow::Result;
use async_trait::async_trait;
use axum::{
    body::{to_bytes, Body},
    extract::ConnectInfo,
    http::{HeaderMap, Method, Request, StatusCode},
    Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::{Signer, SigningKey};
use funtidesk_account::{
    config::API,
    crypto,
    devices::{payload_hash, AckPayload, FamilyMember, FamilyPayload, SyncPayload},
    mail::MailJob,
    registry::KeyRegistry,
    store::{SessionRequest, Store, TooManySessions},
    App,
};
use rand::RngCore;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicI64, Ordering},
        Arc, Mutex,
    },
};
use tokio::sync::mpsc;
use tower::ServiceExt;

#[derive(Default)]
struct Registry(Mutex<HashMap<String, [u8; 32]>>);
#[async_trait]
impl KeyRegistry for Registry {
    async fn key(&self, id: &str) -> Result<Option<[u8; 32]>> {
        Ok(self.0.lock().unwrap().get(id).copied())
    }
}

struct Fixture {
    router: Router,
    clock: Arc<AtomicI64>,
    mail: mpsc::Receiver<MailJob>,
    registry: Arc<Registry>,
}
struct Reply {
    status: StatusCode,
    headers: HeaderMap,
    body: Value,
}

impl Fixture {
    fn new() -> Self {
        let (mail, receiver) = mpsc::channel(20);
        let clock = Arc::new(AtomicI64::new(1_800_000_000));
        let registry = Arc::new(Registry::default());
        let now = clock.clone();
        let app = App::new(
            Store::memory([7; 32]).unwrap(),
            mail,
            registry.clone(),
            vec![],
        )
        .with_clock(Arc::new(move || now.load(Ordering::SeqCst)));
        Self {
            router: funtidesk_account::router(app),
            clock,
            mail: receiver,
            registry,
        }
    }
    fn advance(&self, seconds: i64) {
        self.clock.fetch_add(seconds, Ordering::SeqCst);
    }
    async fn call(
        &self,
        method: Method,
        route: &str,
        headers: &[(&str, String)],
        body: Value,
    ) -> Reply {
        let mut builder = Request::builder()
            .method(method)
            .uri(format!("{API}{route}"))
            .header("host", "desk.funti.cc")
            .header("content-type", "application/json");
        for (key, value) in headers {
            builder = builder.header(*key, value);
        }
        let mut request = builder.body(Body::from(body.to_string())).unwrap();
        request.extensions_mut().insert(ConnectInfo(
            "192.0.2.1:12345".parse::<std::net::SocketAddr>().unwrap(),
        ));
        let response = self.router.clone().oneshot(request).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
        let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        Reply {
            status,
            headers,
            body,
        }
    }
    async fn start(&mut self, email: &str) -> (String, Value, MailJob) {
        let boot = self
            .call(
                Method::GET,
                "/auth/bootstrap",
                &[("x-funti-client", "native".into())],
                json!({}),
            )
            .await;
        let context = boot.body["login_context"].as_str().unwrap().to_owned();
        let headers = vec![
            ("x-funti-client", "native".into()),
            ("x-funti-login", context.clone()),
        ];
        let begin = self
            .call(
                Method::POST,
                "/auth/request",
                &headers,
                json!({"email":email}),
            )
            .await;
        assert_eq!(begin.status, StatusCode::ACCEPTED);
        let job = self.mail.recv().await.unwrap();
        (context, begin.body, job)
    }
    async fn login(&mut self, email: &str) -> String {
        let (context, challenge, mail) = self.start(email).await;
        let response = self
            .verify(
                &context,
                challenge["challenge_id"].as_str().unwrap(),
                &mail.code,
            )
            .await;
        assert_eq!(response.status, StatusCode::OK);
        response.body["token"].as_str().unwrap().to_owned()
    }
    async fn verify(&self, context: &str, id: &str, code: &str) -> Reply {
        self.call(
            Method::POST,
            "/auth/verify",
            &[
                ("x-funti-client", "native".into()),
                ("x-funti-login", context.into()),
            ],
            json!({"challenge_id":id,"code":code}),
        )
        .await
    }
    fn key(&self, id: &str) -> SigningKey {
        let mut secret = [0_u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut secret);
        let key = SigningKey::from_bytes(&secret);
        self.registry
            .0
            .lock()
            .unwrap()
            .insert(id.into(), key.verifying_key().to_bytes());
        key
    }
    async fn bind(&self, token: &str, id: &str, key: &SigningKey) -> String {
        let nonce = self
            .call(
                Method::POST,
                "/devices/bind/nonce",
                &auth(token),
                json!({"funti_id":id,"pk":pk(key)}),
            )
            .await;
        assert_eq!(nonce.status, StatusCode::OK);
        let response = self.call(Method::POST,"/devices/bind",&auth(token),json!({"nonce":nonce.body["nonce"],"signature":sign(&nonce.body,key),"name":"Домашний компьютер","version":"1.5.0-ft.1"})).await;
        assert_eq!(response.status, StatusCode::OK);
        response.body["device_id"].as_str().unwrap().into()
    }
    async fn signed(
        &self,
        token: Option<&str>,
        device: &str,
        action: &str,
        payload: Value,
        key: &SigningKey,
    ) -> Reply {
        let headers = token.map(auth).unwrap_or_default();
        let nonce = self
            .call(
                Method::POST,
                &format!("/devices/{device}/{action}/nonce"),
                &headers,
                json!({"payload_hash":payload_hash(&payload).unwrap()}),
            )
            .await;
        assert_eq!(nonce.status, StatusCode::OK);
        self.call(Method::POST,&format!("/devices/{device}/{action}"),&headers,json!({"nonce":nonce.body["nonce"],"signature":sign(&nonce.body,key),"payload":payload})).await
    }
}
fn auth(token: &str) -> Vec<(&'static str, String)> {
    vec![
        ("x-funti-client", "native".into()),
        ("authorization", format!("Bearer {token}")),
    ]
}
fn pk(key: &SigningKey) -> String {
    STANDARD.encode(key.verifying_key().to_bytes())
}
fn sign(nonce: &Value, key: &SigningKey) -> String {
    let text = if nonce["action"] == "bind" {
        format!(
            "funtidesk-account-v1\nbind\n{}\n{}\n{}\n{}\n{}",
            nonce["account_id"].as_str().unwrap(),
            nonce["funti_id"].as_str().unwrap(),
            nonce["pk"].as_str().unwrap(),
            nonce["nonce"].as_str().unwrap(),
            nonce["expires_at"]
        )
    } else {
        format!(
            "funtidesk-account-v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
            nonce["action"].as_str().unwrap(),
            nonce["account_id"].as_str().unwrap(),
            nonce["device_id"].as_str().unwrap(),
            nonce["funti_id"].as_str().unwrap(),
            nonce["pk"].as_str().unwrap(),
            nonce["payload_hash"].as_str().unwrap(),
            nonce["nonce"].as_str().unwrap(),
            nonce["expires_at"]
        )
    };
    STANDARD.encode(key.sign(text.as_bytes()).to_bytes())
}

#[tokio::test]
async fn code_is_context_bound_and_consumed_once_even_concurrently() {
    let mut f = Fixture::new();
    let (scope, challenge, mail) = f.start("person@example.invalid").await;
    let id = challenge["challenge_id"].as_str().unwrap();
    assert_eq!(
        f.verify(&crypto::token(), id, &mail.code).await.status,
        StatusCode::BAD_REQUEST
    );
    let (a, b) = tokio::join!(
        f.verify(&scope, id, &mail.code),
        f.verify(&scope, id, &mail.code)
    );
    assert_eq!(
        [a.status, b.status]
            .iter()
            .filter(|s| **s == StatusCode::OK)
            .count(),
        1
    );
    assert_eq!(
        f.verify(&scope, id, &mail.code).await.body,
        json!({"error":"invalid_code"})
    );
}

#[tokio::test]
async fn session_limit_preserves_the_code_until_a_session_is_released() {
    let mut f = Fixture::new();
    let mut first = String::new();
    for _ in 0..20 {
        let token = f.login("session-limit@example.invalid").await;
        if first.is_empty() {
            first = token;
        }
        f.advance(3601);
    }
    let (scope, challenge, mail) = f.start("session-limit@example.invalid").await;
    let id = challenge["challenge_id"].as_str().unwrap();
    for _ in 0..2 {
        let reply = f.verify(&scope, id, &mail.code).await;
        assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(reply.body, json!({"error":"too_many_sessions"}));
    }
    assert_eq!(
        f.call(Method::POST, "/logout", &auth(&first), json!({}))
            .await
            .status,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        f.verify(&scope, id, &mail.code).await.status,
        StatusCode::OK
    );
    assert_eq!(
        f.verify(&scope, id, &mail.code).await.body,
        json!({"error":"invalid_code"})
    );
}

#[tokio::test]
async fn five_attempts_expiry_and_unknown_code_have_the_same_response() {
    let mut f = Fixture::new();
    let (scope, challenge, mail) = f.start("person@example.invalid").await;
    let id = challenge["challenge_id"].as_str().unwrap();
    let wrong = if mail.code == "000000" {
        "999999"
    } else {
        "000000"
    };
    for _ in 0..5 {
        assert_eq!(
            f.verify(&scope, id, wrong).await.body,
            json!({"error":"invalid_code"})
        );
    }
    assert_eq!(
        f.verify(&scope, id, &mail.code).await.body,
        json!({"error":"invalid_code"})
    );
    f.advance(61);
    let (scope, challenge, mail) = f.start("person@example.invalid").await;
    f.advance(300);
    let expired = f
        .verify(
            &scope,
            challenge["challenge_id"].as_str().unwrap(),
            &mail.code,
        )
        .await;
    let unknown = f.verify(&scope, &crypto::token(), &mail.code).await;
    assert_eq!(expired.status, unknown.status);
    assert_eq!(expired.body, unknown.body);
}

#[tokio::test]
async fn new_challenge_replaces_the_old_one_without_resetting_address_limits() {
    let mut f = Fixture::new();
    let (scope, old, mail) = f.start("person@example.invalid").await;
    let headers = [
        ("x-funti-client", "native".into()),
        ("x-funti-login", crypto::token()),
    ];
    assert_eq!(
        f.call(
            Method::POST,
            "/auth/request",
            &headers,
            json!({"email":"person@example.invalid"})
        )
        .await
        .status,
        StatusCode::TOO_MANY_REQUESTS
    );
    f.advance(61);
    let next = f
        .call(
            Method::POST,
            "/auth/request",
            &[
                ("x-funti-client", "native".into()),
                ("x-funti-login", scope.clone()),
            ],
            json!({"email":"person@example.invalid"}),
        )
        .await;
    assert_eq!(next.status, StatusCode::ACCEPTED);
    let new_mail = f.mail.recv().await.unwrap();
    assert_eq!(
        f.verify(&scope, old["challenge_id"].as_str().unwrap(), &mail.code)
            .await
            .status,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        f.verify(
            &scope,
            next.body["challenge_id"].as_str().unwrap(),
            &new_mail.code
        )
        .await
        .status,
        StatusCode::OK
    );
}

#[tokio::test]
async fn browser_uses_protected_cookie_and_requires_origin_and_csrf_for_changes() {
    let mut f = Fixture::new();
    let boot = f.call(Method::GET, "/auth/bootstrap", &[], json!({})).await;
    let cookie = boot.headers["set-cookie"].to_str().unwrap();
    for required in [
        "__Host-funti-login=",
        "Secure",
        "HttpOnly",
        "SameSite=Strict",
        "Path=/",
    ] {
        assert!(cookie.contains(required));
    }
    assert!(!cookie.contains("Domain="));
    let login_cookie = cookie.split(';').next().unwrap().to_owned();
    let headers = vec![
        ("cookie", login_cookie.clone()),
        ("origin", "https://desk.funti.cc".into()),
        ("x-funti-csrf", boot.body["csrf"].as_str().unwrap().into()),
    ];
    let begin = f
        .call(
            Method::POST,
            "/auth/request",
            &headers,
            json!({"email":"person@example.invalid"}),
        )
        .await;
    let mail = f.mail.recv().await.unwrap();
    let verify = f
        .call(
            Method::POST,
            "/auth/verify",
            &headers,
            json!({"challenge_id":begin.body["challenge_id"],"code":mail.code}),
        )
        .await;
    assert_eq!(verify.status, StatusCode::OK);
    assert!(verify.body.get("token").is_none());
    let session_cookie = verify
        .headers
        .get_all("set-cookie")
        .iter()
        .map(|h| h.to_str().unwrap())
        .find(|v| v.starts_with("__Host-funti-account="))
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    for (route, body) in [
        ("/library/favorites", json!({"revision":0,"favorites":[]})),
        ("/library/history/clear", json!({"history_epoch":0})),
    ] {
        assert_eq!(
            f.call(
                Method::POST,
                route,
                &[("cookie", session_cookie.clone())],
                body
            )
            .await
            .status,
            StatusCode::FORBIDDEN
        );
    }
    assert_eq!(
        f.call(
            Method::POST,
            "/logout",
            &[("cookie", session_cookie.clone())],
            json!({})
        )
        .await
        .status,
        StatusCode::FORBIDDEN
    );
    let changes = vec![
        ("cookie", session_cookie.clone()),
        ("origin", "https://desk.funti.cc".into()),
        ("x-funti-csrf", verify.body["csrf"].as_str().unwrap().into()),
    ];
    let mut foreign = changes.clone();
    foreign[1].1 = "https://foreign.invalid".into();
    assert_eq!(
        f.call(Method::POST, "/logout", &foreign, json!({}))
            .await
            .status,
        StatusCode::FORBIDDEN
    );
    let mut mixed = auth(&crypto::token());
    mixed.push(("cookie", session_cookie.clone()));
    assert_eq!(
        f.call(Method::GET, "/session", &mixed, json!({}))
            .await
            .status,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        f.call(Method::POST, "/logout", &changes, json!({}))
            .await
            .status,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        f.call(
            Method::GET,
            "/session",
            &[("cookie", session_cookie)],
            json!({})
        )
        .await
        .status,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn logout_all_revokes_every_token_but_keeps_signed_revocation_delivery() {
    let mut f = Fixture::new();
    let first = f.login("person@example.invalid").await;
    let key = f.key("111111");
    let source = f.bind(&first, "111111", &key).await;
    f.advance(61);
    let second = f.login("person@example.invalid").await;
    let remove = f
        .call(
            Method::POST,
            "/family/remove",
            &auth(&second),
            json!({"target_pk":pk(&key),"request_id":crypto::token()}),
        )
        .await;
    assert_eq!(remove.status, StatusCode::OK);
    assert_eq!(
        f.call(Method::POST, "/logout-all", &auth(&second), json!({}))
            .await
            .status,
        StatusCode::NO_CONTENT
    );
    for token in [&first, &second] {
        assert_eq!(
            f.call(Method::GET, "/devices", &auth(token), json!({}))
                .await
                .status,
            StatusCode::UNAUTHORIZED
        );
    }
    let sync = f
        .signed(None, &source, "sync", json!(SyncPayload { after: 0 }), &key)
        .await;
    assert_eq!(sync.status, StatusCode::OK);
    assert!(sync.body["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|e| e["event_id"] == remove.body["event_id"]));
    assert!(sync.body.get("email").is_none());
    assert!(sync.body.get("devices").is_none());
}

#[tokio::test]
async fn bind_requires_the_registered_key_and_nonce_cannot_be_replayed() {
    let mut f = Fixture::new();
    let token = f.login("person@example.invalid").await;
    let key = f.key("111111");
    let other = f.key("222222");
    let nonce = f
        .call(
            Method::POST,
            "/devices/bind/nonce",
            &auth(&token),
            json!({"funti_id":"111111","pk":pk(&other)}),
        )
        .await;
    let forged = f.call(Method::POST,"/devices/bind",&auth(&token),json!({"nonce":nonce.body["nonce"],"signature":sign(&nonce.body,&other),"name":"Ноутбук","version":"1"})).await;
    assert_eq!(forged.status, StatusCode::BAD_REQUEST);
    let nonce = f
        .call(
            Method::POST,
            "/devices/bind/nonce",
            &auth(&token),
            json!({"funti_id":"111111","pk":pk(&key)}),
        )
        .await;
    let body = json!({"nonce":nonce.body["nonce"],"signature":sign(&nonce.body,&key),"name":"Ноутбук","version":"1"});
    let headers = auth(&token);
    let (a, b) = tokio::join!(
        f.call(Method::POST, "/devices/bind", &headers, body.clone()),
        f.call(Method::POST, "/devices/bind", &headers, body)
    );
    assert_eq!(
        [a.status, b.status]
            .iter()
            .filter(|s| **s == StatusCode::OK)
            .count(),
        1
    );
    let list = f
        .call(Method::GET, "/devices", &auth(&token), json!({}))
        .await;
    assert_eq!(list.body["devices"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn email_login_cannot_upload_another_device_copy_or_transfer_its_key() {
    let mut f = Fixture::new();
    let owner = f.login("person@example.invalid").await;
    let key = f.key("111111");
    let source = f.bind(&owner, "111111", &key).await;
    let intruder = f.login("another@example.invalid").await;
    let payload = FamilyPayload {
        name: "Ноутбук".into(),
        version: "1".into(),
        members: vec![],
    };
    let attempt = f
        .call(
            Method::POST,
            &format!("/devices/{source}/family/nonce"),
            &auth(&intruder),
            json!({"payload_hash":payload_hash(&payload).unwrap()}),
        )
        .await;
    assert_eq!(attempt.status, StatusCode::BAD_REQUEST);
    let nonce = f
        .call(
            Method::POST,
            "/devices/bind/nonce",
            &auth(&intruder),
            json!({"funti_id":"111111","pk":pk(&key)}),
        )
        .await;
    assert_eq!(f.call(Method::POST,"/devices/bind",&auth(&intruder),json!({"nonce":nonce.body["nonce"],"signature":sign(&nonce.body,&key),"name":"Ноутбук","version":"1"})).await.status,StatusCode::BAD_REQUEST);
    assert_eq!(
        f.call(Method::GET, "/devices", &auth(&intruder), json!({}))
            .await
            .body["devices"],
        json!([])
    );
    assert_eq!(
        f.call(
            Method::POST,
            "/family/remove",
            &auth(&intruder),
            json!({"target_pk":pk(&key),"request_id":crypto::token()})
        )
        .await
        .status,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn family_is_display_only_and_revocations_replay_after_ack_or_old_copy() {
    let mut f = Fixture::new();
    let token = f.login("person@example.invalid").await;
    let a = f.key("111111");
    let b = f.key("222222");
    let source = f.bind(&token, "111111", &a).await;
    let payload = json!(FamilyPayload {
        name: "Домашний компьютер".into(),
        version: "1".into(),
        members: vec![FamilyMember {
            id: "222222".into(),
            name: "Ноутбук".into(),
            pk: pk(&b)
        }]
    });
    assert_eq!(
        f.signed(Some(&token), &source, "family", payload.clone(), &a)
            .await
            .status,
        StatusCode::OK
    );
    let family = f
        .call(Method::GET, "/family", &auth(&token), json!({}))
        .await;
    assert!(family.body["sources"][0]["members"][0]
        .get("rights")
        .is_none());
    let request = json!({"target_pk":pk(&b),"request_id":crypto::token()});
    let removal = f
        .call(
            Method::POST,
            "/family/remove",
            &auth(&token),
            request.clone(),
        )
        .await;
    let repeat = f
        .call(Method::POST, "/family/remove", &auth(&token), request)
        .await;
    assert_eq!(removal.body["event_id"], repeat.body["event_id"]);
    let event = removal.body["event_id"].as_i64().unwrap();
    let sync = f
        .signed(None, &source, "sync", json!(SyncPayload { after: 0 }), &a)
        .await;
    assert_eq!(sync.body["events"][0]["event_id"], event);
    assert_eq!(
        f.signed(
            None,
            &source,
            "ack",
            json!(AckPayload {
                events: vec![event]
            }),
            &a
        )
        .await
        .status,
        StatusCode::OK
    );
    assert!(f
        .call(Method::GET, "/family/removals", &auth(&token), json!({}))
        .await
        .body["deliveries"][0]["acknowledged_at"]
        .is_i64());
    assert_eq!(
        f.signed(Some(&token), &source, "family", payload, &a)
            .await
            .status,
        StatusCode::OK
    );
    assert_eq!(
        f.signed(None, &source, "sync", json!(SyncPayload { after: 0 }), &a)
            .await
            .body["events"][0]["event_id"],
        event
    );
    let later = f.key("333333");
    let late_source = f.bind(&token, "333333", &later).await;
    assert_eq!(
        f.signed(
            None,
            &late_source,
            "sync",
            json!(SyncPayload { after: 0 }),
            &later
        )
        .await
        .body["events"][0]["event_id"],
        event
    );
}

#[tokio::test]
async fn changed_key_for_same_id_gets_new_identity_without_family() {
    let mut f = Fixture::new();
    let token = f.login("person@example.invalid").await;
    let old = f.key("111111");
    let first = f.bind(&token, "111111", &old).await;
    let new = f.key("111111");
    let second = f.bind(&token, "111111", &new).await;
    assert_ne!(first, second);
    assert_eq!(
        f.call(Method::GET, "/family", &auth(&token), json!({}))
            .await
            .body["sources"],
        json!([])
    );
    assert_eq!(f.bind(&token, "111111", &new).await, second);
}

#[tokio::test]
async fn concurrent_source_nonces_remain_usable() {
    let mut f = Fixture::new();
    let token = f.login("person@example.invalid").await;
    let key = f.key("111111");
    let source = f.bind(&token, "111111", &key).await;
    let removal = f
        .call(
            Method::POST,
            "/family/remove",
            &auth(&token),
            json!({"target_pk":pk(&key),"request_id":crypto::token()}),
        )
        .await;
    for (action, payload, headers) in [
        ("sync", json!({"after":0}), vec![]),
        ("ack", json!({"events":[removal.body["event_id"]]}), vec![]),
        (
            "family",
            json!({"name":"Ноутбук","version":"1","members":[]}),
            auth(&token),
        ),
    ] {
        let route = format!("/devices/{source}/{action}");
        let request = json!({"payload_hash":payload_hash(&payload).unwrap()});
        let first = f
            .call(
                Method::POST,
                &format!("{route}/nonce"),
                &headers,
                request.clone(),
            )
            .await;
        let rival = f
            .call(Method::POST, &format!("{route}/nonce"), &headers, request)
            .await;
        assert_eq!(rival.status, StatusCode::OK);
        assert_ne!(first.body["nonce"], rival.body["nonce"]);
        let reply = f.call(Method::POST, &route, &headers,
            json!({"nonce":first.body["nonce"],"signature":sign(&first.body,&key),"payload":payload})).await;
        assert_eq!(reply.status, StatusCode::OK, "{action}");
    }
}

#[tokio::test]
async fn rebinding_same_key_updates_address_without_losing_deliveries() {
    let mut f = Fixture::new();
    let token = f.login("person@example.invalid").await;
    let key = f.key("111111");
    let source = f.bind(&token, "111111", &key).await;
    let before = f
        .call(Method::GET, "/devices", &auth(&token), json!({}))
        .await;
    let removal = f
        .call(
            Method::POST,
            "/family/remove",
            &auth(&token),
            json!({"target_pk":pk(&key),"request_id":crypto::token()}),
        )
        .await;
    f.registry
        .0
        .lock()
        .unwrap()
        .insert("222222".into(), key.verifying_key().to_bytes());
    f.advance(61);
    assert_eq!(f.bind(&token, "222222", &key).await, source);
    let after = f
        .call(Method::GET, "/devices", &auth(&token), json!({}))
        .await;
    assert_eq!(after.body["devices"].as_array().unwrap().len(), 1);
    assert_eq!(after.body["devices"][0]["funti_id"], "222222");
    assert_eq!(
        after.body["devices"][0]["bound_at"],
        before.body["devices"][0]["bound_at"]
    );
    assert!(
        after.body["devices"][0]["last_seen"].as_i64().unwrap()
            > before.body["devices"][0]["last_seen"].as_i64().unwrap()
    );
    let sync = f
        .signed(None, &source, "sync", json!({"after":0}), &key)
        .await;
    assert_eq!(sync.body["events"][0]["event_id"], removal.body["event_id"]);
}

#[tokio::test]
async fn rejected_mail_requests_do_not_exhaust_everyones_send_budget() {
    let mut f = Fixture::new();
    let (context, _, _) = f.start("person@example.invalid").await;
    let headers = [
        ("x-funti-client", "native".into()),
        ("x-funti-login", context),
    ];
    for _ in 0..25 {
        assert_eq!(
            f.call(
                Method::POST,
                "/auth/request",
                &headers,
                json!({"email":"person@example.invalid"})
            )
            .await
            .status,
            StatusCode::TOO_MANY_REQUESTS
        );
    }
    let next = f
        .call(
            Method::POST,
            "/auth/request",
            &[
                ("x-funti-client", "native".into()),
                ("x-funti-login", crypto::token()),
            ],
            json!({"email":"another@example.invalid"}),
        )
        .await;
    assert_eq!(next.status, StatusCode::ACCEPTED);
    assert_eq!(f.mail.try_recv().unwrap().email, "another@example.invalid");
}

#[test]
fn native_token_cannot_bypass_browser_session_limit() {
    let mut db = Store::memory([3; 32]).unwrap();
    let mut first = String::new();
    let mut now = 1_800_000_000;
    for _ in 0..20 {
        let context = crypto::token();
        let challenge = db
            .begin_login(
                "person@example.invalid",
                &context,
                "192.0.2.1",
                "123456",
                now,
            )
            .unwrap()
            .unwrap();
        let issued = db
            .verify_login(
                &challenge,
                &context,
                "123456",
                "192.0.2.1",
                SessionRequest::Native,
                now,
            )
            .unwrap()
            .unwrap();
        if first.is_empty() {
            first = issued.token;
        }
        now += 3601;
    }
    let context = crypto::token();
    let challenge = db
        .begin_login(
            "person@example.invalid",
            &context,
            "192.0.2.1",
            "123456",
            now,
        )
        .unwrap()
        .unwrap();
    assert!(db
        .verify_login(
            &challenge,
            &context,
            "123456",
            "192.0.2.1",
            SessionRequest::Browser {
                previous_hash: Some(&crypto::digest(first.as_bytes()))
            },
            now
        )
        .err()
        .unwrap()
        .is::<TooManySessions>());
    assert!(db.authenticate(&first, false, now).unwrap().is_some());
}

#[test]
fn limits_and_code_hashes_survive_service_restart() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("account.sqlite3");
    let context = crypto::token();
    let challenge;
    {
        let mut db = Store::open(&path, [3; 32]).unwrap();
        challenge = db
            .begin_login(
                "person@example.invalid",
                &context,
                "192.0.2.1",
                "123456",
                1_800_000_000,
            )
            .unwrap()
            .unwrap();
    }
    let raw = std::fs::read(&path).unwrap();
    assert!(!raw.windows(6).any(|w| w == b"123456"));
    let mut db = Store::open(&path, [3; 32]).unwrap();
    assert!(db
        .begin_login(
            "person@example.invalid",
            &crypto::token(),
            "192.0.2.2",
            "654321",
            1_800_000_001
        )
        .unwrap()
        .is_none());
    assert!(db
        .verify_login(
            &challenge,
            &context,
            "123456",
            "192.0.2.1",
            SessionRequest::Native,
            1_800_000_001
        )
        .unwrap()
        .is_some());
}

#[tokio::test]
async fn library_favorites_are_account_scoped_and_stale_writes_do_not_restore_removals() {
    let mut f = Fixture::new();
    let a = f.login("library-a@example.test").await;
    f.advance(61);
    let b = f.login("library-b@example.test").await;
    let read = f.call(Method::GET, "/library", &auth(&a), json!({})).await;
    assert_eq!(read.body["revision"], 0);
    let update =
        json!({"revision":0,"favorites":[{"funti_id":"111111","name":"<img onerror=alert(1)>"}]});
    assert_eq!(
        f.call(
            Method::POST,
            "/library/favorites",
            &auth(&a),
            update.clone()
        )
        .await
        .status,
        StatusCode::OK
    );
    assert_eq!(
        f.call(Method::GET, "/library", &auth(&b), json!({}))
            .await
            .body["favorites"],
        json!([])
    );
    assert_eq!(
        f.call(
            Method::POST,
            "/library/favorites",
            &auth(&a),
            json!({"revision":1,"favorites":[]})
        )
        .await
        .status,
        StatusCode::OK
    );
    assert_eq!(
        f.call(Method::POST, "/library/favorites", &auth(&a), update)
            .await
            .status,
        StatusCode::CONFLICT
    );
    assert_eq!(
        f.call(Method::GET, "/library", &auth(&a), json!({}))
            .await
            .body["favorites"],
        json!([])
    );
    assert_eq!(f.call(Method::POST,"/library/favorites",&auth(&a),json!({"revision":2,"favorites":[{"funti_id":"111111","name":"PC","password":"secret"}]})).await.status,StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        f.call(Method::GET, "/library", &[], json!({})).await.status,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn library_history_retries_clear_and_foreign_sources() {
    let mut f = Fixture::new();
    let a = f.login("history-a@example.test").await;
    let key = f.key("123456");
    let device = f.bind(&a, "123456", &key).await;
    f.advance(61);
    let b = f.login("history-b@example.test").await;
    let payload = json!({"history_epoch":0,"entry":{"event_id":"a".repeat(64),"source_device_id":device,"funti_id":"654321","name":"PC","connected_at":f.clock.load(Ordering::SeqCst)}});
    assert_eq!(
        f.call(Method::POST, "/library/history", &auth(&b), payload.clone())
            .await
            .status,
        StatusCode::BAD_REQUEST
    );
    for _ in 0..2 {
        assert_eq!(
            f.call(Method::POST, "/library/history", &auth(&a), payload.clone())
                .await
                .status,
            StatusCode::OK
        );
    }
    let read = f.call(Method::GET, "/library", &auth(&a), json!({})).await;
    assert_eq!(read.body["history"].as_array().unwrap().len(), 1);
    assert_eq!(
        f.call(
            Method::POST,
            "/library/history/clear",
            &auth(&a),
            json!({"history_epoch":0})
        )
        .await
        .status,
        StatusCode::OK
    );
    assert_eq!(
        f.call(Method::POST, "/library/history", &auth(&a), payload)
            .await
            .status,
        StatusCode::CONFLICT
    );
    assert_eq!(
        f.call(Method::GET, "/library", &auth(&a), json!({}))
            .await
            .body["history"],
        json!([])
    );
}
