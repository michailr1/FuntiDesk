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
    db.execute_batch(include_str!("../src/schema-recovery.sql"))
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
        3
    );
}
