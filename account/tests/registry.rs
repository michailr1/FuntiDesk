#![cfg(unix)]
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::SigningKey;
use funtidesk_account::registry::{KeyRegistry, UnixRegistry};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[tokio::test]
async fn registry_reads_only_the_registered_key_over_the_private_socket() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("hbbs.sock");
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let key = SigningKey::from_bytes(&[5; 32]).verifying_key().to_bytes();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut stream = BufReader::new(stream);
        let mut request = String::new();
        stream.read_line(&mut request).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&request).unwrap(),
            serde_json::json!({"id":"111111"})
        );
        stream
            .get_mut()
            .write_all(format!("{{\"pk\":\"{}\"}}\n", STANDARD.encode(key)).as_bytes())
            .await
            .unwrap();
    });
    assert_eq!(UnixRegistry(path).key("111111").await.unwrap(), Some(key));
    server.await.unwrap();
}

#[tokio::test]
async fn absent_or_malformed_registry_never_trusts_a_client_supplied_key() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("hbbs.sock");
    assert!(UnixRegistry(path.clone()).key("111111").await.is_err());
    let listener = tokio::net::UnixListener::bind(&path).unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        stream.write_all(b"{\"pk\":\"AAAA\"}\n").await.unwrap();
    });
    assert!(UnixRegistry(path).key("111111").await.is_err());
    server.await.unwrap();
}
