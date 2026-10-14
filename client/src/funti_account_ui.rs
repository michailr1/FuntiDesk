//! FUNTIDESK: bridge 1.80 dispatches a normal Rust function to its worker pool.
//! The UI runtime starts once here; the service uses its existing IPC runtime.

use hbb_common::{
    log,
    tokio::{
        self,
        sync::{mpsc, Semaphore},
    },
};
use std::{
    sync::{mpsc as reply_channel, Arc, Mutex},
    time::Duration,
};

struct Request {
    action: String,
    payload: String,
    reply: reply_channel::SyncSender<String>,
}

lazy_static::lazy_static! {
    static ref REQUESTS: Mutex<Option<mpsc::Sender<Request>>> = Mutex::new(None);
}

pub fn start_ui() {
    let mut requests = REQUESTS.lock().unwrap();
    if requests.is_some() {
        return;
    }
    let (sender, mut receiver) = mpsc::channel::<Request>(4);
    let started = std::thread::Builder::new()
        .name("funti-account-ffi".into())
        .spawn(move || {
            // Runtime construction is on its dedicated startup thread, outside Tokio.
            // The existing Flutter runner blocks on an online-query queue when idle.
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(_) => {
                    log::warn!("FuntiDesk account: UI runner unavailable");
                    return;
                }
            };
            runtime.block_on(async move {
                let slots = Arc::new(Semaphore::new(8));
                while let Some(request) = receiver.recv().await {
                    let Ok(permit) = slots.clone().try_acquire_owned() else {
                        let _ = request.reply.send(error("funti-account-busy"));
                        continue;
                    };
                    tokio::spawn(async move {
                        let _permit = permit;
                        let result = super::call(request.action, request.payload).await;
                        let _ = request.reply.send(result);
                    });
                }
            });
        });
    if started.is_ok() {
        *requests = Some(sender);
    } else {
        log::warn!("FuntiDesk account: UI runner unavailable");
    }
}

pub fn call_blocking(action: String, payload: String) -> String {
    // Dart receives a Future; only the bridge's ordinary worker may wait here.
    if tokio::runtime::Handle::try_current().is_ok() {
        return error("funti-account-busy");
    }
    let sender = REQUESTS.lock().unwrap().clone();
    let Some(sender) = sender else {
        return error("funti-account-service-unavailable");
    };
    let (reply, receiver) = reply_channel::sync_channel(1);
    if sender
        .try_send(Request {
            action,
            payload,
            reply,
        })
        .is_err()
    {
        return error("funti-account-busy");
    }
    receiver
        .recv_timeout(Duration::from_secs(155))
        .unwrap_or_else(|_| error("funti-account-service-unavailable"))
}

fn error(key: &str) -> String {
    serde_json::json!({"error":key}).to_string()
}
