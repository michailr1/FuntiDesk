use funtidesk_account::{
    crypto,
    store::{SessionRequest, Store, TooManySessions},
};
const NOW: i64 = 1_800_000_000;
fn email(store: &mut Store, value: &str) -> funtidesk_account::store::Issued {
    let scope = crypto::token();
    let challenge = store
        .begin_login(value, &scope, "192.0.2.1", "123456", NOW)
        .unwrap()
        .unwrap();
    store
        .verify_login(
            &challenge,
            &scope,
            "123456",
            "192.0.2.1",
            SessionRequest::Browser {
                previous_hash: None,
            },
            NOW,
        )
        .unwrap()
        .unwrap()
}
#[test]
fn telegram_only_browser_bound_one_use_no_fake_email() {
    let mut db = Store::memory([7; 32]).unwrap();
    let id = db
        .telegram_begin("browser-a", None, "192.0.2.1", "A1234B5678", NOW)
        .unwrap()
        .unwrap();
    assert_eq!(
        db.telegram_status(&id, "browser-b", NOW).unwrap(),
        "expired"
    );
    assert_eq!(
        db.telegram_status(&id, "browser-a", NOW).unwrap(),
        "pending"
    );
    assert!(db
        .telegram_finish(&id, "browser-a", None, None, NOW)
        .unwrap()
        .is_none());
    assert!(db.telegram_approve("A1234B5678", 101, NOW).unwrap());
    assert!(!db.telegram_approve("A1234B5678", 102, NOW).unwrap());
    assert!(db
        .telegram_finish(&id, "browser-b", None, None, NOW)
        .unwrap()
        .is_none());
    let issued = db
        .telegram_finish(&id, "browser-a", None, None, NOW)
        .unwrap()
        .unwrap();
    let auth = db.authenticate(&issued.token, true, NOW).unwrap().unwrap();
    let info = db.session(&auth, NOW).unwrap().unwrap();
    assert!(info.email.is_none());
    assert!(info.telegram_linked);
    assert!(!db.telegram_unlink(&auth, NOW).unwrap());
    assert!(db
        .telegram_finish(&id, "browser-a", None, None, NOW)
        .unwrap()
        .is_none());
    let another = db
        .telegram_begin("new-browser", None, "192.0.2.2", "C1234D5678", NOW)
        .unwrap()
        .unwrap();
    assert!(db.telegram_approve("C1234D5678", 101, NOW + 61).unwrap());
    let again = db
        .telegram_finish(&another, "new-browser", None, None, NOW + 61)
        .unwrap()
        .unwrap();
    assert_eq!(again.account, issued.account);
}
#[test]
fn email_link_preserves_account_and_unlink_revokes_access_without_affecting_other_challenges() {
    let mut db = Store::memory([8; 32]).unwrap();
    let issued = email(&mut db, "one@example.invalid");
    let auth = db.authenticate(&issued.token, true, NOW).unwrap().unwrap();
    let id = db
        .telegram_begin("link-browser", Some(&auth), "192.0.2.1", "01234ABCDE", NOW)
        .unwrap()
        .unwrap();
    assert!(db.telegram_approve("01234ABCDE", 101, NOW).unwrap());
    assert!(db
        .telegram_finish(&id, "link-browser", None, None, NOW)
        .unwrap()
        .is_none());
    let linked = db
        .telegram_finish(&id, "link-browser", Some(&auth), Some(&auth.hash), NOW)
        .unwrap()
        .unwrap();
    assert_eq!(linked.account, issued.account);
    assert!(db.authenticate(&issued.token, true, NOW).unwrap().is_none());
    let current = db.authenticate(&linked.token, true, NOW).unwrap().unwrap();
    assert!(db.session(&current, NOW).unwrap().unwrap().telegram_linked);
    let other = db
        .telegram_begin("other-browser", None, "192.0.2.2", "FEDCB56789", NOW)
        .unwrap()
        .unwrap();
    db.telegram_approve("FEDCB56789", 202, NOW).unwrap();
    assert!(db.telegram_unlink(&current, NOW).unwrap());
    assert!(db.authenticate(&linked.token, true, NOW).unwrap().is_none());
    assert_eq!(
        db.telegram_status(&other, "other-browser", NOW).unwrap(),
        "approved"
    );
    assert!(db
        .telegram_finish(&other, "other-browser", None, None, NOW)
        .unwrap()
        .is_some());
}
#[test]
fn no_implicit_merge_replaced_challenges_expire_and_rate_limits_apply() {
    let mut db = Store::memory([9; 32]).unwrap();
    let one = email(&mut db, "one@example.invalid");
    let two = email(&mut db, "two@example.invalid");
    let first = db.authenticate(&one.token, true, NOW).unwrap().unwrap();
    let second = db.authenticate(&two.token, true, NOW).unwrap().unwrap();
    let a = db
        .telegram_begin("first", Some(&first), "192.0.2.1", "ABCDEF0123", NOW)
        .unwrap()
        .unwrap();
    db.telegram_approve("ABCDEF0123", 101, NOW).unwrap();
    db.telegram_finish(&a, "first", Some(&first), Some(&first.hash), NOW)
        .unwrap()
        .unwrap();
    let b = db
        .telegram_begin("second", Some(&second), "192.0.2.2", "FEDCBA3210", NOW)
        .unwrap()
        .unwrap();
    db.telegram_approve("FEDCBA3210", 101, NOW + 61).unwrap();
    assert!(db
        .telegram_finish(&b, "second", Some(&second), Some(&second.hash), NOW + 61)
        .unwrap()
        .is_none());
    let c = db
        .telegram_begin("replace", None, "192.0.2.3", "00000AAAAA", NOW)
        .unwrap()
        .unwrap();
    db.telegram_begin("replace", None, "192.0.2.3", "11111AAAAA", NOW)
        .unwrap();
    assert_eq!(db.telegram_status(&c, "replace", NOW).unwrap(), "expired");
    assert!(!db.telegram_approve("00000AAAAA", 200, NOW).unwrap());
    let d = db
        .telegram_begin("expires", None, "192.0.2.4", "22222AAAAA", NOW)
        .unwrap()
        .unwrap();
    assert!(!db.telegram_approve("22222AAAAA", 201, NOW + 300).unwrap());
    assert_eq!(
        db.telegram_status(&d, "expires", NOW + 300).unwrap(),
        "expired"
    );
    for i in 0..3 {
        assert!(db
            .telegram_begin(
                "limited",
                None,
                &format!("192.0.2.{}", 10 + i),
                &format!("AAAAA{i:05}"),
                NOW
            )
            .unwrap()
            .is_some());
    }
    assert!(db
        .telegram_begin("limited", None, "192.0.2.99", "BBBBB11111", NOW)
        .unwrap()
        .is_none());
}
#[test]
fn old_session_must_still_be_active_to_finish_link() {
    let mut db = Store::memory([3; 32]).unwrap();
    let issued = email(&mut db, "one@example.invalid");
    let auth = db.authenticate(&issued.token, true, NOW).unwrap().unwrap();
    let id = db
        .telegram_begin("link", Some(&auth), "192.0.2.1", "AAAAABBBBB", NOW)
        .unwrap()
        .unwrap();
    db.telegram_approve("AAAAABBBBB", 101, NOW).unwrap();
    db.logout(&auth, false, NOW).unwrap();
    assert!(db
        .telegram_finish(&id, "link", Some(&auth), Some(&auth.hash), NOW)
        .unwrap()
        .is_none());
}

#[test]
fn telegram_sessions_share_the_existing_twenty_session_limit_and_can_replace_browser_session() {
    let mut db = Store::memory([4; 32]).unwrap();
    let mut last = None;
    for i in 0..21 {
        let now = NOW + 3601 * i;
        let scope = format!("scope-{i}");
        let code = format!("{i:010X}");
        let id = db
            .telegram_begin(&scope, None, "192.0.2.1", &code, now)
            .unwrap()
            .unwrap();
        assert!(db.telegram_approve(&code, 101, now).unwrap());
        if i < 20 {
            last = Some(
                db.telegram_finish(&id, &scope, None, None, now)
                    .unwrap()
                    .unwrap(),
            );
        } else {
            assert!(db
                .telegram_finish(&id, &scope, None, None, now)
                .err()
                .unwrap()
                .is::<TooManySessions>());
            let old = db
                .authenticate(&last.as_ref().unwrap().token, true, now)
                .unwrap()
                .unwrap();
            assert!(db
                .telegram_finish(&id, &scope, None, Some(&old.hash), now)
                .unwrap()
                .is_some());
        }
    }
}
