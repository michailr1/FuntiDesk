//! A mutation is externally visible only after the independent witness fsync.
use crate::{
    crypto,
    store::Store,
    witness::{atomic_file, Client, Head, Snapshot, MAX_DATABASE},
    App,
};
use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::Mutex as AsyncMutex;

pub struct Recovery {
    pub(crate) gate: AsyncMutex<()>,
    pub(crate) workers: Arc<tokio::sync::Semaphore>,
    client: Client,
    directory: PathBuf,
    key: [u8; 32],
}

impl Store {
    pub fn recovery_head(&self) -> Result<(Head, i64)> {
        let (namespace,revision,confirmed,highwater,digest):(String,i64,i64,i64,String)=self.db.query_row("SELECT namespace,revision,confirmed,confirmed_highwater,digest FROM recovery_state WHERE id=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?)))?;
        Ok((
            Head {
                namespace,
                revision: confirmed,
                event_highwater: highwater,
                digest,
            },
            revision,
        ))
    }
    pub fn event_highwater(&self) -> Result<i64> {
        Ok(self.db.query_row(
            "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)",
            [],
            |r| r.get(0),
        )?)
    }
    fn confirm(&mut self, head: &Head) -> Result<()> {
        let (current, revision) = self.recovery_head()?;
        if revision != head.revision
            || current.namespace != head.namespace
            || self.event_highwater()? != head.event_highwater
        {
            bail!("recovery head mismatch");
        }
        self.db.execute(
            "UPDATE recovery_state SET confirmed=?1,digest=?2,confirmed_highwater=?3 WHERE id=1",
            params![head.revision, head.digest, head.event_highwater],
        )?;
        Ok(())
    }
    pub fn backup_file(&self, path: &Path) -> Result<()> {
        let mut options = fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(path)?;
        let mut destination = Connection::open(path)?;
        rusqlite::backup::Backup::new(&self.db, &mut destination)?.run_to_completion(
            128,
            Duration::from_millis(1),
            None,
        )?;
        drop(destination);
        fs::File::open(path)?.sync_all()?;
        Ok(())
    }
}

impl Recovery {
    pub async fn attach(
        mut app: App,
        client: Client,
        directory: PathBuf,
        namespace: String,
        initialize: bool,
    ) -> Result<App> {
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        }
        let remote = client.head().await?;
        if remote.namespace != namespace {
            bail!("witness namespace mismatch");
        }
        let store = app.store.clone();
        let remote_copy = remote.clone();
        let pending = directory.join("pending.json");
        let account_key=tokio::task::spawn_blocking(move || -> Result<[u8;32]> {
            let store=store.lock().map_err(|_|anyhow::anyhow!("store lock failed"))?;
            let (mut local,revision)=store.recovery_head()?;
            if initialize {
                let count:i64=store.db.query_row("SELECT (SELECT COUNT(*) FROM accounts)+(SELECT COUNT(*) FROM devices)+(SELECT COUNT(*) FROM events)",[],|r|r.get(0))?;
                if count!=0 || revision!=0 || remote_copy.revision!=0 || !local.namespace.is_empty() { bail!("initialization requires new empty state"); }
                store.db.execute("UPDATE recovery_state SET namespace=?1 WHERE id=1",[&namespace])?;
                local.namespace=namespace;
            }
            if revision==local.revision {
                if local!=remote_copy { bail!("stale or mismatched account database"); }
            } else {
                let snapshot:Snapshot=serde_json::from_slice(&fs::read(&pending).context("pending recovery snapshot missing")?)?;
                if snapshot.previous!=local || snapshot.head.revision!=revision || snapshot.head.event_highwater!=store.event_highwater()?
                    || !(remote_copy==snapshot.previous || remote_copy==snapshot.head) { bail!("independent witness requires explicit recovery"); }
            }
            Ok(store.key)
        }).await??;
        let key = derive_key(&account_key, &remote.namespace)?;
        let recovery = Arc::new(Self {
            gate: AsyncMutex::new(()),
            workers: Arc::new(tokio::sync::Semaphore::new(32)),
            client,
            directory,
            key,
        });
        recovery.finish_pending(app.store.clone()).await?;
        // Startup cannot prove freshness of non-mirrored, short-lived proofs.
        // Keep legitimate sessions and rate limits, but never revive an old code/nonce.
        let startup = app.store.clone();
        tokio::task::spawn_blocking(move || -> Result<()> {
            startup
                .lock()
                .map_err(|_| anyhow::anyhow!("store lock failed"))?
                .db
                .execute_batch("BEGIN; DELETE FROM challenges; DELETE FROM nonces; COMMIT;")?;
            Ok(())
        })
        .await??;
        app.recovery = Some(recovery);
        Ok(app)
    }
    pub(crate) async fn finish_pending(&self, store: Arc<Mutex<Store>>) -> Result<()> {
        let pending = self.directory.join("pending.json");
        let backup = self.directory.join("capture.sqlite3");
        let key = self.key;
        let before = store.clone();
        let pending_copy = pending.clone();
        let snapshot = tokio::task::spawn_blocking(move || -> Result<Option<Snapshot>> {
            let store = before
                .lock()
                .map_err(|_| anyhow::anyhow!("store lock failed"))?;
            let (previous, revision) = store.recovery_head()?;
            if revision == previous.revision {
                if pending_copy.is_file() {
                    let old: Snapshot = serde_json::from_slice(&fs::read(&pending_copy)?)?;
                    if old.head != previous {
                        bail!("stale pending snapshot mismatch");
                    }
                    old.open(&key)?;
                    fs::remove_file(&pending_copy)?;
                    fs::File::open(pending_copy.parent().context("pending directory missing")?)?
                        .sync_all()?;
                }
                return Ok(None);
            }
            if pending_copy.is_file() {
                let snapshot: Snapshot = serde_json::from_slice(&fs::read(&pending_copy)?)?;
                if snapshot.head.revision != revision
                    || snapshot.head.namespace != previous.namespace
                    || snapshot.previous != previous
                    || snapshot.head.event_highwater != store.event_highwater()?
                {
                    bail!("pending snapshot mismatch");
                }
                snapshot.open(&key)?;
                return Ok(Some(snapshot));
            }
            let captured = (|| -> Result<Snapshot> {
                store.backup_file(&backup)?;
                if fs::metadata(&backup)?.len() > MAX_DATABASE as u64 {
                    bail!("recovery database too large");
                }
                Snapshot::seal(
                    previous,
                    revision,
                    store.event_highwater()?,
                    &key,
                    &fs::read(&backup)?,
                )
            })();
            if backup.is_file() {
                fs::remove_file(&backup)?;
            }
            Ok(Some(captured?))
        })
        .await??;
        let Some(snapshot) = snapshot else {
            return Ok(());
        };
        if !pending.is_file() {
            if self.client.head().await? != snapshot.previous {
                bail!("witness advanced unexpectedly");
            }
            atomic_file(&pending, &serde_json::to_vec(&snapshot)?)?;
        }
        let head = self.client.put(snapshot).await?;
        tokio::task::spawn_blocking(move || -> Result<()> {
            store
                .lock()
                .map_err(|_| anyhow::anyhow!("store lock failed"))?
                .confirm(&head)
        })
        .await??;
        fs::remove_file(&pending)?;
        fs::File::open(&self.directory)?.sync_all()?;
        Ok(())
    }
}

fn derive_key(account_key: &[u8; 32], namespace: &str) -> Result<[u8; 32]> {
    hex::decode(crypto::tag(
        account_key,
        "recovery-encryption-v1",
        &[namespace],
    ))?
    .try_into()
    .map_err(|_| anyhow::anyhow!("recovery key failure"))
}
fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

/// Only the latest authenticated state can be restored, always to a fresh path.
pub async fn restore(client: &Client, account_key: [u8; 32], destination: &Path) -> Result<Head> {
    if destination.exists()
        || sidecar(destination, "-wal").exists()
        || sidecar(destination, "-shm").exists()
    {
        bail!("restore destination must be new");
    }
    let head = client.head().await?;
    let snapshot = client.read().await?;
    if snapshot.head != head || client.head().await? != head {
        bail!("witness changed during restore");
    }
    let bytes = snapshot.open(&derive_key(&account_key, &head.namespace)?)?;
    let parent = destination.parent().context("missing recovery directory")?;
    if !parent.is_dir() {
        bail!("recovery directory must exist");
    }
    let temporary = parent.join(format!(".restore-{}.sqlite3", crypto::token()));
    atomic_file(&temporary, &bytes)?;
    let result = (|| -> Result<()> {
        let mut store = Store::open(&temporary, account_key)?;
        let check: String = store
            .db
            .query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
        let foreign_keys: bool = store.db.prepare("PRAGMA foreign_key_check")?.exists([])?;
        if check != "ok" || foreign_keys {
            bail!("invalid recovery database");
        }
        let (current, revision) = store.recovery_head()?;
        if current.namespace != head.namespace
            || revision != head.revision
            || store.event_highwater()? != head.event_highwater
        {
            bail!("invalid recovery metadata");
        }
        store.db.execute_batch(
            "BEGIN; DELETE FROM sessions; DELETE FROM challenges; DELETE FROM nonces; COMMIT;",
        )?;
        store.confirm(&head)?;
        store.db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        drop(store);
        fs::File::open(&temporary)?.sync_all()?;
        // An atomic link refuses a concurrently created destination instead of overwriting it.
        fs::hard_link(&temporary, destination)?;
        fs::remove_file(&temporary)?;
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    for file in [
        temporary.clone(),
        temporary.with_extension("lock"),
        sidecar(&temporary, "-wal"),
        sidecar(&temporary, "-shm"),
    ] {
        if file.exists() {
            fs::remove_file(file)?;
        }
    }
    result?;
    Ok(head)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        devices::{payload_hash, AckPayload, FamilyMember, FamilyPayload, SyncPayload},
        registry::UnixRegistry,
        store::{Auth, SessionRequest},
        witness::{self, WitnessStore},
    };
    use axum::{
        body::{to_bytes, Body},
        extract::{Request, State},
        http::StatusCode,
        middleware::{self, Next},
        response::{IntoResponse, Response},
    };
    use base64::{engine::general_purpose::STANDARD, Engine};
    use std::sync::atomic::{AtomicU8, Ordering};
    const NOW: i64 = 1_800_000_000;
    const KEY: [u8; 32] = [3; 32];

    struct Fixture {
        dir: tempfile::TempDir,
        client: Client,
        fault: Arc<AtomicU8>,
        task: tokio::task::JoinHandle<()>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.task.abort();
        }
    }
    async fn fault(State(mode): State<Arc<AtomicU8>>, request: Request, next: Next) -> Response {
        if mode.load(Ordering::SeqCst) == 1 {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        }
        let (parts, body) = request.into_parts();
        let bytes = to_bytes(body, witness::MAX_ENVELOPE + 4096).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let lose = json["operation"].get("Put").is_some()
            && mode
                .compare_exchange(2, 0, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok();
        let response = next
            .run(Request::from_parts(parts, Body::from(bytes)))
            .await;
        if lose {
            StatusCode::SERVICE_UNAVAILABLE.into_response()
        } else {
            response
        }
    }
    impl Fixture {
        async fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let namespace = "77".repeat(32);
            let path = dir.path().join("independent");
            WitnessStore::initialize(&path, &namespace, [8; 32]).unwrap();
            let store = WitnessStore::open(&path, [8; 32]).unwrap();
            let fault_mode = Arc::new(AtomicU8::new(0));
            let router = witness::router(store)
                .layer(middleware::from_fn_with_state(fault_mode.clone(), fault));
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = format!("http://{}/v1/witness", listener.local_addr().unwrap());
            let task = tokio::spawn(async move {
                axum::serve(listener, router).await.unwrap();
            });
            Self {
                dir,
                client: Client::new(endpoint, namespace, [8; 32]).unwrap(),
                fault: fault_mode,
                task,
            }
        }
        async fn app(&self, path: &Path, recovery_dir: &str, initialize: bool) -> Result<App> {
            let (tx, _) = tokio::sync::mpsc::channel(20);
            let app = App::new(
                Store::open(path, KEY)?,
                tx,
                Arc::new(UnixRegistry(self.dir.path().join("unused.sock"))),
                vec![],
            );
            Recovery::attach(
                app,
                self.client.clone(),
                self.dir.path().join(recovery_dir),
                "77".repeat(32),
                initialize,
            )
            .await
        }
    }
    fn login(store: &mut Store, scope: &str, now: i64) -> Result<(Auth, String)> {
        let id = store
            .begin_login("person@example.invalid", scope, "192.0.2.1", "123456", now)?
            .unwrap();
        let issued = store
            .verify_login(
                &id,
                scope,
                "123456",
                "192.0.2.1",
                SessionRequest::Native,
                now,
            )?
            .unwrap();
        Ok((
            store.authenticate(&issued.token, false, now)?.unwrap(),
            issued.token,
        ))
    }
    async fn setup(app: &App) -> (Auth, String, String, String, String) {
        app.db(|store| {
            let (auth, token) = login(store, &crypto::token(), NOW)?;
            let pk = |byte| {
                STANDARD.encode(
                    ed25519_dalek::SigningKey::from_bytes(&[byte; 32])
                        .verifying_key()
                        .as_bytes(),
                )
            };
            let target = pk(6);
            let bind = store
                .bind_nonce(&auth, "123456789", &pk(5), "192.0.2.1", NOW)?
                .unwrap();
            let source = store
                .bind_device(&bind, &auth, "Ноутбук", "test", NOW)?
                .unwrap();
            let bind = store
                .bind_nonce(&auth, "223456789", &target, "192.0.2.1", NOW)?
                .unwrap();
            let second = store
                .bind_device(&bind, &auth, "Компьютер", "test", NOW)?
                .unwrap();
            let copy = FamilyPayload {
                name: "Ноутбук".into(),
                version: "test".into(),
                members: vec![FamilyMember {
                    id: "223456789".into(),
                    name: "Компьютер".into(),
                    pk: target.clone(),
                }],
            };
            let nonce = store
                .source_nonce(
                    &source,
                    "family",
                    &payload_hash(&copy)?,
                    Some(&auth),
                    "192.0.2.1",
                    NOW,
                )?
                .unwrap();
            assert!(store.save_family(&nonce, &auth, &copy, NOW)?);
            Ok((auth, token, source, second, target))
        })
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn latest_restore_keeps_revocations_identities_ack_and_highwater_but_invalidates_login() {
        let f = Fixture::new().await;
        let primary = f.dir.path().join("primary.sqlite3");
        let app = f.app(&primary, "recovery", true).await.unwrap();
        let (auth, token, source, second, pk) = setup(&app).await;
        let old = f.dir.path().join("old.sqlite3");
        let old_copy = old.clone();
        app.db(move |s| s.backup_file(&old_copy)).await.unwrap();
        let auth_copy = auth.clone();
        let target = pk.clone();
        let event = app
            .db(move |s| {
                Ok(
                    s.remove_member(&auth_copy, &target, &crypto::token(), NOW + 1)?
                        .unwrap(),
                )
            })
            .await
            .unwrap();
        let source_copy = source.clone();
        app.db(move |s| {
            let payload = AckPayload {
                events: vec![event],
            };
            let nonce = s
                .source_nonce(
                    &source_copy,
                    "ack",
                    &payload_hash(&payload)?,
                    None,
                    "192.0.2.1",
                    NOW + 2,
                )?
                .unwrap();
            assert!(s.acknowledge(&nonce, &payload, NOW + 2)?);
            // Leave an unused challenge and nonce in the captured state.
            s.begin_login(
                "other@example.invalid",
                &crypto::token(),
                "192.0.2.2",
                "654321",
                NOW + 3,
            )?;
            let auth = s.authenticate(&token, false, NOW + 3)?.unwrap();
            s.bind_nonce(
                &auth,
                "323456789",
                &STANDARD.encode(
                    ed25519_dalek::SigningKey::from_bytes(&[9; 32])
                        .verifying_key()
                        .as_bytes(),
                ),
                "192.0.2.1",
                NOW + 3,
            )?;
            Ok(())
        })
        .await
        .unwrap();
        assert!(f.app(&old, "old-recovery", false).await.is_err());
        let head = f.client.head().await.unwrap();
        let restored = f.dir.path().join("restored.sqlite3");
        assert!(restore(&f.client, [4; 32], &restored).await.is_err());
        assert!(!restored.exists());
        assert!(restore(&f.client, KEY, &primary).await.is_err());
        let result = restore(&f.client, KEY, &restored).await.unwrap();
        assert!(result == head && result.event_highwater == event);
        let fresh = f.app(&restored, "fresh-recovery", false).await.unwrap();
        let source_copy = source.clone();
        let second_copy = second.clone();
        let target = pk.clone();
        fresh
            .db(move |s| {
                for table in ["sessions", "challenges", "nonces"] {
                    let count: i64 =
                        s.db.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?;
                    assert_eq!(count, 0);
                }
                let ids: Vec<String> =
                    s.db.prepare("SELECT id FROM devices ORDER BY id")?
                        .query_map([], |r| r.get(0))?
                        .collect::<rusqlite::Result<_>>()?;
                assert!(ids.contains(&source_copy) && ids.contains(&second_copy));
                let ack: i64 = s.db.query_row(
                    "SELECT acknowledged_at FROM deliveries WHERE event_id=?1 AND device_id=?2",
                    params![event, source_copy],
                    |r| r.get(0),
                )?;
                assert_eq!(ack, NOW + 2);
                for id in [&source_copy, &second_copy] {
                    let payload = SyncPayload { after: 0 };
                    let nonce = s
                        .source_nonce(
                            id,
                            "sync",
                            &payload_hash(&payload)?,
                            None,
                            "192.0.2.1",
                            NOW + 4,
                        )?
                        .unwrap();
                    let events = s.sync(&nonce, &payload, NOW + 4)?.unwrap();
                    assert!(events["events"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|v| v["event_id"] == event && v["target_pk"] == target));
                }
                // Restored account IDs are stable; no family rights are imported.
                let (new_auth, _) = login(s, &crypto::token(), NOW + 61)?;
                assert_eq!(new_auth.account, auth.account);
                assert!(s.event_highwater()? > event);
                Ok(())
            })
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn logout_advances_independent_head_and_startup_never_revives_short_lived_proofs() {
        let f = Fixture::new().await;
        let path = f.dir.path().join("primary.sqlite3");
        let app = f.app(&path, "recovery", true).await.unwrap();
        let (auth, token, source, _, _) = setup(&app).await;
        let old = f.dir.path().join("before-logout.sqlite3");
        let copy = old.clone();
        app.db(move |s| s.backup_file(&copy)).await.unwrap();
        let before = f.client.head().await.unwrap();
        app.db(move |s| s.logout(&auth, true, NOW + 1))
            .await
            .unwrap();
        let after = f.client.head().await.unwrap();
        assert!(
            after.revision > before.revision && after.event_highwater == before.event_highwater
        );
        assert!(f.app(&old, "stale-recovery", false).await.is_err());
        let legitimate = app
            .db(move |s| {
                let (_, legitimate) = login(s, &crypto::token(), NOW + 61)?;
                s.begin_login(
                    "other@example.invalid",
                    &crypto::token(),
                    "192.0.2.2",
                    "654321",
                    NOW + 62,
                )?
                .unwrap();
                let payload = SyncPayload { after: 0 };
                s.source_nonce(
                    &source,
                    "sync",
                    &payload_hash(&payload)?,
                    None,
                    "192.0.2.1",
                    NOW + 62,
                )?
                .unwrap();
                Ok(legitimate)
            })
            .await
            .unwrap();
        drop(app);
        let restarted = f.app(&path, "recovery", false).await.unwrap();
        restarted
            .db(move |s| {
                assert!(s.authenticate(&token, false, NOW + 63)?.is_none());
                assert!(s.authenticate(&legitimate, false, NOW + 63)?.is_some());
                for table in ["challenges", "nonces"] {
                    let count: i64 =
                        s.db.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))?;
                    assert_eq!(count, 0);
                }
                Ok(())
            })
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn witness_outage_blocks_results_and_reads_until_durable_confirmation() {
        let f = Fixture::new().await;
        let app = f
            .app(&f.dir.path().join("primary.sqlite3"), "recovery", true)
            .await
            .unwrap();
        let (auth, _, _, _, pk) = setup(&app).await;
        let before = f.client.head().await.unwrap();
        f.fault.store(1, Ordering::SeqCst);
        assert!(app
            .db(move |s| s.remove_member(&auth, &pk, &crypto::token(), NOW + 1))
            .await
            .is_err());
        assert!(app.db(|s| s.event_highwater()).await.is_err());
        f.fault.store(0, Ordering::SeqCst);
        assert!(f.client.head().await.unwrap() == before);
        let event = app.db(|s| s.event_highwater()).await.unwrap();
        assert!(event > before.event_highwater);
        assert_eq!(f.client.head().await.unwrap().event_highwater, event);
    }
    #[tokio::test]
    async fn lost_put_reply_resumes_after_restart_without_duplicate_events() {
        let f = Fixture::new().await;
        let path = f.dir.path().join("primary.sqlite3");
        let app = f.app(&path, "recovery", true).await.unwrap();
        let (auth, _, _, _, pk) = setup(&app).await;
        let request_id = crypto::token();
        let id = request_id.clone();
        let a = auth.clone();
        let p = pk.clone();
        f.fault.store(2, Ordering::SeqCst);
        assert!(app
            .db(move |s| s.remove_member(&a, &p, &id, NOW + 1))
            .await
            .is_err());
        let head = f.client.head().await.unwrap();
        assert!(f.dir.path().join("recovery/pending.json").is_file());
        drop(app);
        let resumed = f.app(&path, "recovery", false).await.unwrap();
        let event = resumed
            .db(move |s| Ok(s.remove_member(&auth, &pk, &request_id, NOW + 1)?.unwrap()))
            .await
            .unwrap();
        assert_eq!(event, head.event_highwater);
        assert!(f.client.head().await.unwrap() == head);
        assert!(!f.dir.path().join("recovery/pending.json").exists());
    }
    #[tokio::test]
    async fn cancelled_request_keeps_gate_until_confirmation_and_unchanged_copy_does_not_grow_log()
    {
        let f = Fixture::new().await;
        let app = f
            .app(&f.dir.path().join("primary.sqlite3"), "recovery", true)
            .await
            .unwrap();
        let (auth, _, source, _, target) = setup(&app).await;
        let head = f.client.head().await.unwrap();
        let copy = FamilyPayload {
            name: "Ноутбук".into(),
            version: "test".into(),
            members: vec![FamilyMember {
                id: "223456789".into(),
                name: "Компьютер".into(),
                pk: target.clone(),
            }],
        };
        let a = auth.clone();
        app.db(move |s| {
            let nonce = s
                .source_nonce(
                    &source,
                    "family",
                    &payload_hash(&copy)?,
                    Some(&a),
                    "192.0.2.1",
                    NOW + 1,
                )?
                .unwrap();
            assert!(s.save_family(&nonce, &a, &copy, NOW + 1)?);
            Ok(())
        })
        .await
        .unwrap();
        assert!(f.client.head().await.unwrap() == head);
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let writer = app.clone();
        let task = tokio::spawn(async move {
            writer
                .db(move |s| {
                    let event = s
                        .remove_member(&auth, &target, &crypto::token(), NOW + 2)?
                        .unwrap();
                    started.send(()).unwrap();
                    wait.recv().unwrap();
                    Ok(event)
                })
                .await
        });
        ready.await.unwrap();
        task.abort();
        // The detached operation still owns one permit and the serialization gate.
        assert_eq!(
            app.recovery.as_ref().unwrap().workers.available_permits(),
            31
        );
        assert!(app.recovery.as_ref().unwrap().gate.try_lock().is_err());
        release.send(()).unwrap();
        let event = app.db(|s| s.event_highwater()).await.unwrap();
        assert!(event > head.event_highwater);
        assert_eq!(f.client.head().await.unwrap().event_highwater, event);
    }
}
