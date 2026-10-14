pub mod config;
pub mod crypto;
pub mod devices;
pub mod mail;
pub mod recovery;
pub mod registry;
mod relay;
pub mod store;
mod web;
pub mod witness;

use anyhow::Result;
use axum::Router;
use std::{
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::mpsc;

#[derive(Clone)]
pub struct App {
    pub(crate) store: Arc<Mutex<store::Store>>,
    pub(crate) key: [u8; 32],
    pub(crate) mail: mpsc::Sender<mail::MailJob>,
    pub(crate) registry: Arc<dyn registry::KeyRegistry>,
    pub(crate) proxies: Arc<Vec<IpAddr>>,
    pub(crate) clock: Arc<dyn Fn() -> i64 + Send + Sync>,
    pub(crate) permits: Arc<tokio::sync::Semaphore>,
    pub(crate) recovery: Option<Arc<recovery::Recovery>>,
}

impl App {
    pub fn new(
        store: store::Store,
        mail: mpsc::Sender<mail::MailJob>,
        registry: Arc<dyn registry::KeyRegistry>,
        proxies: Vec<IpAddr>,
    ) -> Self {
        let key = store.key;
        Self {
            store: Arc::new(Mutex::new(store)),
            key,
            mail,
            registry,
            proxies: Arc::new(proxies),
            clock: Arc::new(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0)
            }),
            permits: Arc::new(tokio::sync::Semaphore::new(32)),
            recovery: None,
        }
    }

    pub fn with_clock(mut self, clock: Arc<dyn Fn() -> i64 + Send + Sync>) -> Self {
        self.clock = clock;
        self
    }

    pub(crate) fn now(&self) -> i64 {
        (self.clock)()
    }

    pub async fn maintain(&self) -> Result<()> {
        let now = self.now();
        self.db(move |db| db.maintain(now)).await
    }

    pub(crate) async fn db<T, F>(&self, call: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut store::Store) -> Result<T> + Send + 'static,
    {
        let store = self.store.clone();
        if let Some(recovery) = self.recovery.clone() {
            let permit = recovery.workers.clone().try_acquire_owned()?;
            // Finish a started mutation even if its HTTP request disappears.
            // The owned task keeps serialization and the queue bound intact.
            return tokio::spawn(async move {
                let _permit = permit;
                let _guard = recovery.gate.lock().await;
                recovery.finish_pending(store.clone()).await?;
                let before = store.clone();
                let result = tokio::task::spawn_blocking(move || {
                    let mut store = before
                        .lock()
                        .map_err(|_| anyhow::anyhow!("store lock failed"))?;
                    call(&mut store)
                })
                .await?;
                recovery.finish_pending(store).await?;
                result
            })
            .await?;
        }
        tokio::task::spawn_blocking(move || {
            let mut store = store
                .lock()
                .map_err(|_| anyhow::anyhow!("store lock failed"))?;
            call(&mut store)
        })
        .await?
    }
}

pub fn router(app: App) -> Router {
    web::router(app)
}

pub fn witness_relay() -> Result<Router> {
    relay::router()
}
