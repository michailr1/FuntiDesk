// Compile and test the actual client policy without screen/audio platform libraries.
#[path = "../../client/src/funti_account_protocol.rs"]
mod protocol;

#[test]
fn automatic_favorites_transfer_merges_local_edits_without_recreating_remote_deletions() {
    use serde_json::json;
    let local = vec![("123456".to_owned(), "Дом".to_owned())];
    let cloud = vec![json!({"funti_id":"654321","name":"Работа"})];
    let merged = protocol::merge_local_favorites(&cloud, &[], &local);
    assert_eq!(
        merged,
        vec![cloud[0].clone(), json!({"funti_id":"123456","name":"Дом"})]
    );
    // Restart after a remote deletion: the unchanged local copy is not re-added.
    assert_eq!(
        protocol::merge_local_favorites(&cloud, &["123456".into()], &local),
        cloud
    );
    // An ordinary local removal while signed out propagates after the next login.
    assert_eq!(
        protocol::merge_local_favorites(&merged, &["123456".into()], &[]),
        cloud
    );
}

#[test]
fn automatic_local_history_import_is_idempotent_scoped_and_contains_no_credentials() {
    let account = "a".repeat(64);
    let source = "b".repeat(64);
    let entry =
        protocol::local_history_entry(&account, &source, "123456", "Дом", 1000, 2000).unwrap();
    assert_eq!(
        entry,
        protocol::local_history_entry(&account, &source, "123456", "Дом", 1000, 2000).unwrap()
    );
    assert_eq!(
        entry
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>(),
        ["connected_at", "event_id", "funti_id", "name"]
    );
    assert_eq!(entry["connected_at"], 1000);
    let other =
        protocol::local_history_entry(&account, &"c".repeat(64), "123456", "Дом", 1000, 2000)
            .unwrap();
    assert_ne!(entry["event_id"], other["event_id"]);
    let other =
        protocol::local_history_entry(&"d".repeat(64), &source, "123456", "Дом", 1000, 2000)
            .unwrap();
    assert_ne!(entry["event_id"], other["event_id"]);
    assert!(protocol::local_history_entry(
        &account,
        &source,
        "host@example.test",
        "Дом",
        1000,
        2000
    )
    .is_none());
    assert!(protocol::local_history_entry(
        &account,
        &source,
        "123456",
        "Дом",
        1000,
        1000 + 90 * 86400
    )
    .is_none());
    assert!(
        protocol::local_history_entry(&account, &source, "123456", "Дом", 2301, 2000).is_none()
    );
}

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
