// Compile and test the actual client policy without screen/audio platform libraries.
#[path = "../../client/src/funti_account_protocol.rs"]
mod protocol;

#[test]
fn client_and_server_construct_the_same_nonce_message_and_payload_hash() {
    let payload = serde_json::json!({"members":[],"name":"Домашний компьютер","version":"1"});
    assert_eq!(
        protocol::payload_hash(&payload).unwrap(),
        funtidesk_account::devices::payload_hash(&payload).unwrap()
    );
    for action in ["bind", "family", "sync", "ack"] {
        let hash = if action == "bind" {
            String::new()
        } else {
            protocol::payload_hash(&payload).unwrap()
        };
        let server = funtidesk_account::devices::Nonce {
            nonce: "a".repeat(64),
            account_id: "b".repeat(64),
            device_id: (action != "bind").then(|| "c".repeat(64)),
            action: action.into(),
            funti_id: "111111".into(),
            pk: "local-key".into(),
            payload_hash: hash.clone(),
            expires_at: 1300,
            session_hash: None,
        };
        let client: protocol::Nonce =
            serde_json::from_value(serde_json::to_value(&server).unwrap()).unwrap();
        // Server time is 1000: even one second of local lag used to fail.
        for client_now in [700, 999, 1000, 1001, 1299] {
            assert_eq!(
                client
                    .message(
                        action,
                        &server.account_id,
                        server.device_id.as_deref(),
                        "111111",
                        "local-key",
                        &hash,
                        client_now
                    )
                    .unwrap(),
                server.message()
            );
        }
    }
}
