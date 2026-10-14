//! A separate outbound-only adapter. The account container stays isolated.
use crate::witness::{bounded, MAX_ENVELOPE};
use anyhow::Result;
use axum::{
    body::Bytes,
    extract::State,
    http::{header, StatusCode},
    middleware,
    response::{IntoResponse, Response},
    routing::post,
    Router,
};
use std::{sync::Arc, time::Duration};

const REMOTE: &str = "https://de.funti.cc:8447/v1/witness";
#[derive(Clone)]
struct Relay {
    http: reqwest::Client,
    endpoint: String,
}
pub fn router() -> Result<Router> {
    build(REMOTE.to_owned())
}
fn build(endpoint: String) -> Result<Router> {
    let http = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(18))
        .build()?;
    Ok(Router::new()
        .route("/v1/witness", post(forward))
        .layer(axum::extract::DefaultBodyLimit::max(MAX_ENVELOPE + 4096))
        .layer(middleware::from_fn_with_state(
            Arc::new(tokio::sync::Semaphore::new(2)),
            bounded,
        ))
        .with_state(Relay { http, endpoint }))
}
async fn forward(State(relay): State<Relay>, body: Bytes) -> Response {
    async fn send(relay: Relay, body: Bytes) -> Result<(StatusCode, Vec<u8>)> {
        let mut response = relay
            .http
            .post(&relay.endpoint)
            .header(header::CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await?;
        if response
            .content_length()
            .is_some_and(|n| n > MAX_ENVELOPE as u64 + 4096)
        {
            anyhow::bail!("witness response too large");
        }
        let status = response.status();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            if bytes.len() + chunk.len() > MAX_ENVELOPE + 4096 {
                anyhow::bail!("witness response too large");
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok((status, bytes))
    }
    match send(relay, body).await {
        Ok((status, bytes)) => (
            status,
            [
                (header::CONTENT_TYPE, "application/json"),
                (header::CACHE_CONTROL, "no-store"),
            ],
            bytes,
        )
            .into_response(),
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        http::Request,
    };
    use tower::ServiceExt;
    #[tokio::test]
    async fn relay_forwards_only_the_body_and_never_follows_redirects() {
        let destination = Router::new().route(
            "/v1/witness",
            post(|headers: axum::http::HeaderMap, body: Bytes| async move {
                assert!(!headers.contains_key(header::COOKIE));
                assert!(!headers.contains_key(header::AUTHORIZATION));
                (
                    StatusCode::TEMPORARY_REDIRECT,
                    [
                        (header::LOCATION, "http://127.0.0.1:9/private"),
                        (header::SET_COOKIE, "secret=hidden"),
                    ],
                    body,
                )
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v1/witness", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, destination).await.unwrap();
        });
        let reply = build(url)
            .unwrap()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/witness")
                    .header(header::COOKIE, "session=hidden")
                    .header(header::AUTHORIZATION, "Bearer hidden")
                    .body(Body::from("opaque"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(reply.status(), StatusCode::TEMPORARY_REDIRECT);
        assert!(!reply.headers().contains_key(header::LOCATION));
        assert!(!reply.headers().contains_key(header::SET_COOKIE));
        assert_eq!(to_bytes(reply.into_body(), 100).await.unwrap(), "opaque");
        task.abort();
    }
}
