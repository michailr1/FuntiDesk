use funtidesk_account::{
    crypto,
    library::{Change, Favorite, FavoritesUpdate},
    store::Store,
};
use rusqlite::{params, Connection};

#[test]
fn upgrade_keeps_existing_account_and_session_and_reopen_keeps_synchronized_lists() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("account.sqlite3");
    let now = 1_800_000_000;
    let token = "a".repeat(64);
    let db = Connection::open(&path).unwrap();
    db.execute_batch(include_str!("../src/schema.sql")).unwrap();
    db.execute_batch(include_str!("fixtures/schema-v2.sql"))
        .unwrap();
    db.execute(
        "INSERT INTO accounts(id,email,created_at) VALUES('existing','person@example.invalid',?1)",
        [now],
    )
    .unwrap();
    db.execute("INSERT INTO sessions(token_hash,account_id,browser,created_at,expires_at) VALUES(?1,'existing',0,?2,?3)",params![crypto::digest(token.as_bytes()),now,now+3600]).unwrap();
    drop(db);
    let mut store = Store::open(&path, [7; 32]).unwrap();
    let auth = store.authenticate(&token, false, now).unwrap().unwrap();
    assert_eq!(
        store.session(&auth, now).unwrap().unwrap().email,
        "person@example.invalid"
    );
    assert!(store
        .library(&auth, now)
        .unwrap()
        .unwrap()
        .favorites
        .is_empty());
    assert!(matches!(
        store
            .favorites_update(
                &auth,
                FavoritesUpdate {
                    revision: 0,
                    favorites: vec![Favorite {
                        funti_id: "123456789".into(),
                        name: "PC".into()
                    }]
                },
                now
            )
            .unwrap(),
        Change::Applied(_)
    ));
    drop(store);
    let store = Store::open(&path, [7; 32]).unwrap();
    let auth = store.authenticate(&token, false, now).unwrap().unwrap();
    assert_eq!(
        store.library(&auth, now).unwrap().unwrap().favorites[0].funti_id,
        "123456789"
    );
    drop(store);
    let db = Connection::open(path).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        5
    );
}

#[test]
fn removing_witness_preserves_v3_data_sessions_and_revocations_without_network() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("account.sqlite3");
    let now = 1_800_000_000;
    let token = "a".repeat(64);
    let revoked = "b".repeat(64);
    let db = Connection::open(&path).unwrap();
    db.execute_batch(include_str!("../src/schema.sql")).unwrap();
    db.execute_batch(include_str!("fixtures/schema-v2.sql"))
        .unwrap();
    db.execute_batch(include_str!("fixtures/schema-v3-library.sql"))
        .unwrap();
    db.execute_batch("INSERT INTO accounts VALUES('existing','person@example.invalid',1000,0);
        INSERT INTO devices VALUES('device','existing','123456789','public-key','PC','1',1000,1100);
        INSERT INTO family_copies VALUES('device',3,'[]',1100);
        INSERT INTO events VALUES(42,'existing','remove','removed-public-key',1100,'request');
        INSERT INTO deliveries VALUES(42,'device',1150);
        INSERT INTO account_library VALUES('existing',4,2,'[{\"funti_id\":\"987654321\",\"name\":\"Home\"}]');
        INSERT INTO connection_history VALUES('existing','event','device','987654321','Home',1200);
        UPDATE recovery_state SET namespace='offline',revision=21,confirmed=19 WHERE id=1;").unwrap();
    for (value, revoked_at) in [(&token, None), (&revoked, Some(now - 1))] {
        db.execute(
            "INSERT INTO sessions VALUES(?1,'existing',0,1000,?2,?3)",
            params![crypto::digest(value.as_bytes()), now + 3600, revoked_at],
        )
        .unwrap();
    }
    fn contents(db: &Connection) -> Vec<Vec<Vec<rusqlite::types::Value>>> {
        [
            "accounts",
            "sessions",
            "devices",
            "family_copies",
            "events",
            "deliveries",
            "account_library",
            "connection_history",
        ]
        .iter()
        .map(|table| {
            let columns = if *table == "events" {
                "id,account_id,kind,target_pk,created_at,request_id"
            } else {
                "*"
            };
            let mut stmt = db
                .prepare(&format!("SELECT {columns} FROM {table} ORDER BY 1"))
                .unwrap();
            let columns = stmt.column_count();
            stmt.query_map([], |row| (0..columns).map(|i| row.get(i)).collect())
                .unwrap()
                .collect::<rusqlite::Result<Vec<_>>>()
                .unwrap()
        })
        .collect()
    }
    let before = contents(&db);
    drop(db);
    let store = Store::open(&path, [7; 32]).unwrap();
    assert!(store.authenticate(&token, false, now).unwrap().is_some());
    assert!(store.authenticate(&revoked, false, now).unwrap().is_none());
    drop(store);
    let db = Connection::open(&path).unwrap();
    assert_eq!(contents(&db), before);
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        5
    );
    assert_eq!(db.query_row("SELECT count(*) FROM sqlite_master WHERE name='recovery_state' OR (type='trigger' AND name LIKE 'recovery_%')", [], |r| r.get::<_,i64>(0)).unwrap(), 0);
    assert_eq!(
        db.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    drop(db);
    drop(Store::open(&path, [7; 32]).unwrap());
}

#[test]
fn v4_migration_preserves_deliveries_and_cancellation_survives_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("account.sqlite3");
    let now = 1_800_000_000;
    let token = "a".repeat(64);
    let db = Connection::open(&path).unwrap();
    for sql in [
        include_str!("../src/schema.sql"),
        include_str!("../src/schema-library.sql"),
        include_str!("../src/schema-local.sql"),
    ] {
        db.execute_batch(sql).unwrap();
    }
    db.execute_batch(
        "INSERT INTO accounts VALUES('account','person@example.invalid',1000,0);
        INSERT INTO devices VALUES('device','account','123456789','public-key','PC','1',1000,1100);
        INSERT INTO events VALUES(42,'account','remove','removed-public-key',1100,'request');
        INSERT INTO deliveries VALUES(42,'device',1150);",
    )
    .unwrap();
    db.execute(
        "INSERT INTO sessions VALUES(?1,'account',0,1000,?2,NULL)",
        params![crypto::digest(token.as_bytes()), now + 3600],
    )
    .unwrap();
    drop(db);
    let mut store = Store::open(&path, [7; 32]).unwrap();
    let auth = store.authenticate(&token, false, now).unwrap().unwrap();
    let rows = store.removals(&auth, now).unwrap().unwrap();
    assert!(rows["deliveries"][0]["cancelled_at"].is_null());
    assert!(store.cancel_removal(&auth, 42, now).unwrap());
    drop(store);
    let store = Store::open(&path, [7; 32]).unwrap();
    let auth = store.authenticate(&token, false, now).unwrap().unwrap();
    let rows = store.removals(&auth, now).unwrap().unwrap();
    assert_eq!(rows["deliveries"][0]["cancelled_at"], now);
    assert_eq!(rows["deliveries"][0]["acknowledged_at"], 1150);
    assert_eq!(rows["deliveries"][0]["target_pk"], "removed-public-key");
    drop(store);
    let db = Connection::open(path).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        5
    );
    assert_eq!(
        db.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(
        db.query_row("SELECT pk FROM devices", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "public-key"
    );
}
