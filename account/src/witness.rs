//! Independent encrypted recovery state. No email session grants witness access.

use crate::crypto;
use anyhow::{bail, Context, Result};
use axum::{
    extract::{Request as HttpRequest, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Response as HttpResponse},
    routing::post,
    Extension, Json, Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

pub const MAX_DATABASE: usize = 16 * 1024 * 1024;
pub const MAX_ENVELOPE: usize = 24 * 1024 * 1024;
pub const MAX_RECORDS: usize = 100_000;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Head {
    pub namespace: String,
    pub revision: i64,
    pub event_highwater: i64,
    pub digest: String,
}

impl Head {
    pub fn empty(namespace: String) -> Result<Self> {
        if !crypto::is_token(&namespace) {
            bail!("invalid witness namespace");
        }
        Ok(Self {
            namespace,
            revision: 0,
            event_highwater: 0,
            digest: String::new(),
        })
    }
    fn valid(&self) -> bool {
        crypto::is_token(&self.namespace)
            && self.revision >= 0
            && self.event_highwater >= 0
            && if self.revision == 0 {
                self.digest.is_empty() && self.event_highwater == 0
            } else {
                crypto::is_token(&self.digest)
            }
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub head: Head,
    pub previous: Head,
    pub sealed: String,
}

impl Snapshot {
    pub fn seal(
        previous: Head,
        revision: i64,
        event_highwater: i64,
        key: &[u8; 32],
        database: &[u8],
    ) -> Result<Self> {
        if database.len() > MAX_DATABASE
            || !previous.valid()
            || revision <= previous.revision
            || event_highwater < previous.event_highwater
        {
            bail!("invalid recovery snapshot");
        }
        let mut nonce = [0; 24];
        rand::rngs::OsRng.fill_bytes(&mut nonce);
        let aad = serde_json::to_vec(&(&previous, revision, event_highwater))?;
        let cipher = XChaCha20Poly1305::new(key.into());
        let encrypted = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: database,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow::anyhow!("snapshot encryption failed"))?;
        let mut sealed = nonce.to_vec();
        sealed.extend(encrypted);
        let head = Head {
            namespace: previous.namespace.clone(),
            revision,
            event_highwater,
            digest: crypto::digest(&sealed),
        };
        Ok(Self {
            head,
            previous,
            sealed: STANDARD.encode(sealed),
        })
    }
    pub fn open(&self, key: &[u8; 32]) -> Result<Vec<u8>> {
        let sealed = self.checked_bytes()?;
        let aad = serde_json::to_vec(&(
            &self.previous,
            self.head.revision,
            self.head.event_highwater,
        ))?;
        XChaCha20Poly1305::new(key.into())
            .decrypt(
                XNonce::from_slice(&sealed[..24]),
                Payload {
                    msg: &sealed[24..],
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow::anyhow!("snapshot authentication failed"))
    }
    fn checked_bytes(&self) -> Result<Vec<u8>> {
        if !self.head.valid()
            || !self.previous.valid()
            || self.head.namespace != self.previous.namespace
            || self.head.revision <= self.previous.revision
            || self.head.event_highwater < self.previous.event_highwater
            || self.sealed.len() > MAX_ENVELOPE
        {
            bail!("invalid snapshot metadata");
        }
        let bytes = STANDARD.decode(&self.sealed)?;
        if bytes.len() < 40
            || bytes.len() > MAX_DATABASE + 40
            || STANDARD.encode(&bytes) != self.sealed
            || crypto::digest(&bytes) != self.head.digest
        {
            bail!("invalid snapshot body");
        }
        Ok(bytes)
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Record {
    head: Head,
    previous: Head,
    mac: String,
}

impl Record {
    fn new(snapshot: &Snapshot, key: &[u8; 32]) -> Result<Self> {
        let bytes = serde_json::to_string(&(&snapshot.head, &snapshot.previous))?;
        Ok(Self {
            head: snapshot.head.clone(),
            previous: snapshot.previous.clone(),
            mac: crypto::tag(key, "witness-record-v1", &[&bytes]),
        })
    }
    fn valid(&self, key: &[u8; 32]) -> Result<bool> {
        let bytes = serde_json::to_string(&(&self.head, &self.previous))?;
        Ok(self.head.valid()
            && self.previous.valid()
            && crypto::matches(key, "witness-record-v1", &[&bytes], &self.mac))
    }
}

pub fn atomic_file(path: &Path, data: &[u8]) -> Result<()> {
    let parent = path.parent().context("missing state directory")?;
    let temp = parent.join(format!(".pending-{}", crypto::token()));
    let result = (|| {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp)?;
        file.write_all(data)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

pub struct WitnessStore {
    directory: PathBuf,
    key: [u8; 32],
    head: Head,
    records: usize,
    _lock: File,
}

impl WitnessStore {
    /// Initialization is explicit; runtime never invents an empty head after loss.
    pub fn initialize(directory: &Path, namespace: &str, key: [u8; 32]) -> Result<()> {
        if directory.exists() && fs::read_dir(directory)?.next().is_some() {
            bail!("witness directory must be empty");
        }
        fs::create_dir_all(directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        }
        let head = Head::empty(namespace.to_owned())?;
        atomic_file(&directory.join("namespace"), namespace.as_bytes())?;
        atomic_file(&directory.join("HEAD"), &serde_json::to_vec(&head)?)?;
        // A wrong machine key must fail before any record can be accepted.
        let verifier = crypto::tag(&key, "witness-key-v1", &[namespace]);
        atomic_file(&directory.join("key-verifier"), verifier.as_bytes())
    }
    pub fn open(directory: &Path, key: [u8; 32]) -> Result<Self> {
        let namespace = fs::read_to_string(directory.join("namespace"))?;
        if !crypto::matches(
            &key,
            "witness-key-v1",
            &[&namespace],
            &fs::read_to_string(directory.join("key-verifier"))?,
        ) {
            bail!("witness key mismatch");
        }
        let mut options = OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(directory.join("lock"))?;
        fs2::FileExt::try_lock_exclusive(&lock)?;
        let declared: Head = serde_json::from_slice(&fs::read(directory.join("HEAD"))?)?;
        let mut head = Head::empty(namespace)?;
        let mut declared_seen = declared == head;
        let mut records = Vec::new();
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".record") {
                let revision = name.trim_end_matches(".record").parse::<i64>()?;
                records.push((revision, entry.path()));
            }
        }
        records.sort_by_key(|r| r.0);
        let count = records.len();
        if count > MAX_RECORDS {
            bail!("witness record limit exceeded");
        }
        for (revision, path) in records {
            let record: Record = serde_json::from_slice(&fs::read(path)?)?;
            if !record.valid(&key)? || record.previous != head || record.head.revision != revision {
                bail!("witness record gap or corruption");
            }
            head = record.head;
            declared_seen |= declared == head;
        }
        if !declared_seen
            || !declared.valid()
            || declared.namespace != head.namespace
            || declared.revision > head.revision
        {
            bail!("witness head is incomplete");
        }
        let mut store = Self {
            directory: directory.to_owned(),
            key,
            head,
            records: count,
            _lock: lock,
        };
        if store.head.revision > 0 {
            store.read()?;
        }
        if declared != store.head {
            atomic_file(
                &store.directory.join("HEAD"),
                &serde_json::to_vec(&store.head)?,
            )?;
        }
        store.prune()?;
        Ok(store)
    }
    pub fn head(&self) -> Head {
        self.head.clone()
    }
    pub fn read(&self) -> Result<Snapshot> {
        if self.head.revision == 0 {
            bail!("no recovery state yet");
        }
        let snapshot: Snapshot = serde_json::from_slice(&fs::read(
            self.directory
                .join(format!("{}.sealed", self.head.revision)),
        )?)?;
        snapshot.checked_bytes()?;
        if snapshot.head != self.head {
            bail!("witness snapshot is incomplete");
        }
        Ok(snapshot)
    }
    pub fn put(&mut self, snapshot: &Snapshot) -> Result<Head> {
        snapshot.checked_bytes()?;
        if snapshot.head == self.head {
            if self.read()? != *snapshot {
                bail!("witness replay mismatch");
            }
            return Ok(self.head());
        }
        if snapshot.previous != self.head {
            bail!("witness compare-and-swap failed");
        }
        if self.records >= MAX_RECORDS {
            bail!("witness record capacity exhausted");
        }
        let record = Record::new(snapshot, &self.key)?;
        let record_path = self
            .directory
            .join(format!("{}.record", snapshot.head.revision));
        if record_path.exists() {
            let old: Record = serde_json::from_slice(&fs::read(&record_path)?)?;
            let body: Snapshot = serde_json::from_slice(&fs::read(
                self.directory
                    .join(format!("{}.sealed", snapshot.head.revision)),
            )?)?;
            if old != record || body != *snapshot {
                bail!("witness durable record conflict");
            }
        } else {
            atomic_file(
                &self
                    .directory
                    .join(format!("{}.sealed", snapshot.head.revision)),
                &serde_json::to_vec(snapshot)?,
            )?;
            atomic_file(&record_path, &serde_json::to_vec(&record)?)?;
        }
        self.head = snapshot.head.clone();
        self.records += 1;
        atomic_file(
            &self.directory.join("HEAD"),
            &serde_json::to_vec(&self.head)?,
        )?;
        self.prune()?;
        Ok(self.head())
    }
    fn prune(&mut self) -> Result<()> {
        let mut files = Vec::new();
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            if let Some(name) = entry.file_name().to_str() {
                if let Some(number) = name.strip_suffix(".sealed") {
                    files.push((number.parse::<i64>()?, entry.path()));
                }
            }
        }
        files.sort_by_key(|r| std::cmp::Reverse(r.0));
        for (_, path) in files.into_iter().skip(2) {
            fs::remove_file(path)?;
        }
        File::open(&self.directory)?.sync_all()?;
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub enum Operation {
    Head,
    Read,
    Put(Snapshot),
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    nonce: String,
    namespace: String,
    operation: Operation,
    mac: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
enum Reply {
    Head(Head),
    Snapshot(Snapshot),
    Rejected,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Response {
    nonce: String,
    reply: Reply,
    mac: String,
}

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    endpoint: String,
    namespace: String,
    key: [u8; 32],
}
impl Client {
    pub fn new(endpoint: String, namespace: String, key: [u8; 32]) -> Result<Self> {
        Head::empty(namespace.clone())?;
        let url = reqwest::Url::parse(&endpoint)?;
        let internal = url.scheme() == "http"
            && matches!(
                url.host_str(),
                Some("127.0.0.1" | "[::1]" | "localhost" | "funtidesk-account-witness-relay")
            );
        if !(url.scheme() == "https" || internal)
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            bail!("invalid witness endpoint");
        }
        let http = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20))
            .build()?;
        Ok(Self {
            http,
            endpoint,
            namespace,
            key,
        })
    }
    async fn call(&self, operation: Operation) -> Result<Reply> {
        let nonce = crypto::token();
        let signed = serde_json::to_string(&(&nonce, &self.namespace, &operation))?;
        let request = Request {
            nonce: nonce.clone(),
            namespace: self.namespace.clone(),
            operation,
            mac: crypto::tag(&self.key, "witness-request-v1", &[&signed]),
        };
        let response = self.http.post(&self.endpoint).json(&request).send().await?;
        if !response.status().is_success()
            || response
                .content_length()
                .is_some_and(|n| n > MAX_ENVELOPE as u64 + 4096)
        {
            bail!("witness unavailable");
        }
        let mut response = response;
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            if bytes.len() + chunk.len() > MAX_ENVELOPE + 4096 {
                bail!("witness response too large");
            }
            bytes.extend_from_slice(&chunk);
        }
        let reply: Response = serde_json::from_slice(&bytes)?;
        let signed = serde_json::to_string(&(&reply.nonce, &reply.reply))?;
        if reply.nonce != nonce
            || !crypto::matches(&self.key, "witness-response-v1", &[&signed], &reply.mac)
        {
            bail!("witness response authentication failed");
        }
        Ok(reply.reply)
    }
    pub async fn head(&self) -> Result<Head> {
        match self.call(Operation::Head).await? {
            Reply::Head(head) if head.valid() && head.namespace == self.namespace => Ok(head),
            _ => bail!("witness head unavailable"),
        }
    }
    pub async fn read(&self) -> Result<Snapshot> {
        match self.call(Operation::Read).await? {
            Reply::Snapshot(snapshot) if snapshot.head.namespace == self.namespace => {
                snapshot.checked_bytes()?;
                Ok(snapshot)
            }
            _ => bail!("witness snapshot unavailable"),
        }
    }
    pub async fn put(&self, snapshot: Snapshot) -> Result<Head> {
        let expected = snapshot.head.clone();
        match self.call(Operation::Put(snapshot)).await? {
            Reply::Head(head) if head == expected => Ok(head),
            _ => bail!("witness did not confirm snapshot"),
        }
    }
}

pub fn router(store: WitnessStore) -> Router {
    Router::new()
        .route("/v1/witness", post(handle))
        .layer(axum::extract::DefaultBodyLimit::max(MAX_ENVELOPE + 4096))
        .layer(middleware::from_fn_with_state(
            Arc::new(tokio::sync::Semaphore::new(2)),
            bounded,
        ))
        .with_state(Arc::new(Mutex::new(store)))
}
async fn handle(
    State(store): State<Arc<Mutex<WitnessStore>>>,
    Extension(permit): Extension<Arc<tokio::sync::OwnedSemaphorePermit>>,
    Json(request): Json<Request>,
) -> Result<Json<Response>, StatusCode> {
    let result = tokio::task::spawn_blocking(move || -> Result<Response> {
        let _permit = permit;
        let mut store = store
            .lock()
            .map_err(|_| anyhow::anyhow!("witness lock failed"))?;
        let signed =
            serde_json::to_string(&(&request.nonce, &request.namespace, &request.operation))?;
        if !crypto::is_token(&request.nonce)
            || request.namespace != store.head.namespace
            || !crypto::matches(&store.key, "witness-request-v1", &[&signed], &request.mac)
        {
            bail!("witness request authentication failed");
        }
        let reply = match request.operation {
            Operation::Head => Reply::Head(store.head()),
            Operation::Read => store.read().map(Reply::Snapshot).unwrap_or(Reply::Rejected),
            Operation::Put(snapshot) => store
                .put(&snapshot)
                .map(Reply::Head)
                .unwrap_or(Reply::Rejected),
        };
        let signed = serde_json::to_string(&(&request.nonce, &reply))?;
        Ok(Response {
            nonce: request.nonce,
            reply,
            mac: crypto::tag(&store.key, "witness-response-v1", &[&signed]),
        })
    })
    .await
    .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?
    .map_err(|_| StatusCode::UNAUTHORIZED)?;
    Ok(Json(result))
}

pub(crate) async fn bounded(
    State(permits): State<Arc<tokio::sync::Semaphore>>,
    mut request: HttpRequest,
    next: Next,
) -> HttpResponse {
    let Ok(permit) = permits.try_acquire_owned() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    let permit = Arc::new(permit);
    request.extensions_mut().insert(permit.clone());
    match tokio::time::timeout(Duration::from_secs(20), next.run(request)).await {
        Ok(response) => response,
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const KEY: [u8; 32] = [1; 32];
    fn fixture() -> (tempfile::TempDir, WitnessStore) {
        let dir = tempfile::tempdir().unwrap();
        WitnessStore::initialize(dir.path(), &"33".repeat(32), KEY).unwrap();
        let store = WitnessStore::open(dir.path(), KEY).unwrap();
        (dir, store)
    }
    #[test]
    fn authenticated_snapshot_rejects_changes_wrong_keys_and_decreasing_watermarks() {
        let head = Head::empty("33".repeat(32)).unwrap();
        let snapshot = Snapshot::seal(head, 10, 8, &KEY, b"private database").unwrap();
        assert_eq!(snapshot.open(&KEY).unwrap(), b"private database");
        assert!(snapshot.open(&[2; 32]).is_err());
        let mut changed = snapshot.clone();
        changed.head.event_highwater += 1;
        assert!(changed.open(&KEY).is_err());
        let mut changed = snapshot.clone();
        let replacement = if changed.sealed.starts_with('A') {
            "B"
        } else {
            "A"
        };
        changed.sealed.replace_range(0..1, replacement);
        assert!(changed.open(&KEY).is_err());
        assert!(Snapshot::seal(snapshot.head, 11, 7, &KEY, b"db").is_err());
    }
    #[test]
    fn durable_chain_rejects_rollback_and_conflicts_and_keeps_two_ciphertexts() {
        let (dir, mut store) = fixture();
        let first = Snapshot::seal(store.head(), 1, 1, &KEY, b"first").unwrap();
        store.put(&first).unwrap();
        let second = Snapshot::seal(store.head(), 4, 2, &KEY, b"second").unwrap();
        store.put(&second).unwrap();
        let third = Snapshot::seal(store.head(), 8, 2, &KEY, b"third").unwrap();
        store.put(&third).unwrap();
        assert!(store.put(&first).is_err());
        assert!(store.put(&third).unwrap() == third.head);
        let conflicting = Snapshot::seal(second.head.clone(), 8, 2, &KEY, b"different").unwrap();
        assert!(store.put(&conflicting).is_err());
        let count = store.records;
        store.records = MAX_RECORDS;
        let fourth = Snapshot::seal(store.head(), 9, 3, &KEY, b"fourth").unwrap();
        assert!(store.put(&fourth).is_err());
        assert!(store.put(&third).unwrap() == third.head);
        store.records = count;
        assert!(!dir.path().join("1.sealed").exists());
        assert!(dir.path().join("4.sealed").exists() && dir.path().join("8.sealed").exists());
        assert!(WitnessStore::initialize(dir.path(), &"33".repeat(32), KEY).is_err());
        assert!(WitnessStore::open(dir.path(), KEY).is_err());
        drop(store);
        assert!(WitnessStore::open(dir.path(), [2; 32]).is_err());
        let reopened = WitnessStore::open(dir.path(), KEY).unwrap();
        assert!(reopened.head() == third.head && reopened.read().unwrap() == third);
    }
    #[test]
    fn crash_before_head_replace_recovers_durable_record_but_missing_record_fails_closed() {
        let (dir, mut store) = fixture();
        let first = Snapshot::seal(store.head(), 1, 1, &KEY, b"first").unwrap();
        store.put(&first).unwrap();
        let second = Snapshot::seal(store.head(), 4, 2, &KEY, b"second").unwrap();
        store.put(&second).unwrap();
        drop(store);
        atomic_file(
            &dir.path().join("HEAD"),
            &serde_json::to_vec(&first.head).unwrap(),
        )
        .unwrap();
        let reopened = WitnessStore::open(dir.path(), KEY).unwrap();
        assert!(reopened.head() == second.head);
        drop(reopened);
        fs::remove_file(dir.path().join("1.record")).unwrap();
        assert!(WitnessStore::open(dir.path(), KEY).is_err());
    }
    #[test]
    fn mismatched_head_or_missing_ciphertext_never_resets_authority() {
        let (dir, mut store) = fixture();
        let first = Snapshot::seal(store.head(), 1, 1, &KEY, b"first").unwrap();
        store.put(&first).unwrap();
        drop(store);
        let mut wrong = first.head.clone();
        wrong.digest = "aa".repeat(32);
        atomic_file(
            &dir.path().join("HEAD"),
            &serde_json::to_vec(&wrong).unwrap(),
        )
        .unwrap();
        assert!(WitnessStore::open(dir.path(), KEY).is_err());
        atomic_file(
            &dir.path().join("HEAD"),
            &serde_json::to_vec(&first.head).unwrap(),
        )
        .unwrap();
        fs::remove_file(dir.path().join("1.sealed")).unwrap();
        assert!(WitnessStore::open(dir.path(), KEY).is_err());
    }

    #[tokio::test]
    async fn fresh_head_rejects_replayed_or_forged_responses_and_untrusted_plaintext_transport() {
        use std::sync::atomic::{AtomicU8, Ordering};
        let mode = Arc::new(AtomicU8::new(0));
        let endpoint = Router::new()
            .route(
                "/v1/witness",
                post(
                    |State(mode): State<Arc<AtomicU8>>, Json(request): Json<Request>| async move {
                        let nonce = if mode.load(Ordering::SeqCst) == 0 {
                            "00".repeat(32)
                        } else {
                            request.nonce
                        };
                        let reply = Reply::Head(Head::empty("33".repeat(32)).unwrap());
                        let signed = serde_json::to_string(&(&nonce, &reply)).unwrap();
                        let mac = if mode.load(Ordering::SeqCst) == 1 {
                            "00".repeat(32)
                        } else {
                            crypto::tag(&KEY, "witness-response-v1", &[&signed])
                        };
                        Json(Response { nonce, reply, mac })
                    },
                ),
            )
            .with_state(mode.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/v1/witness", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, endpoint).await.unwrap();
        });
        let client = Client::new(url, "33".repeat(32), KEY).unwrap();
        assert!(client.head().await.is_err());
        mode.store(1, Ordering::SeqCst);
        assert!(client.head().await.is_err());
        mode.store(2, Ordering::SeqCst);
        assert!(client.head().await.unwrap() == Head::empty("33".repeat(32)).unwrap());
        assert!(Client::new(
            "http://untrusted.example.invalid/v1/witness".into(),
            "33".repeat(32),
            KEY
        )
        .is_err());
        assert!(Client::new(
            "https://de.funti.cc:8446/v1/witness?key=hidden".into(),
            "33".repeat(32),
            KEY
        )
        .is_err());
        task.abort();
    }
}
