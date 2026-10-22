// FUNTIDESK: supervision of the `--server` child by the Windows service.
//
// Unattended access after a reboot (2026-10-22, MINIPC): connections timed
// out before anyone signed in, and worked after an RDP reconnect made the
// service start a new `--server`. The service loop itself is upstream; this
// module adds what it lacks: a log of every launch, its reason and result,
// child exits, the sessions it chose from, the child's registration on the
// rendezvous server, and a restart of a child that stays unregistered.
// Logs go to the service log (`C:\Windows\ServiceProfiles\LocalService\
// AppData\Roaming\FuntiDesk\log\service`) and are written before sign-in.
// No secrets: session ids, process ids, Windows error codes and states only.

use super::{get_available_sessions, get_current_session, is_share_rdp, launch_server};
use crate::ipc;
use hbb_common::{log, ResultType};
use std::{
    sync::atomic::{AtomicU32, Ordering},
    time::{Duration, Instant},
};
use winapi::{
    shared::{
        minwindef::{DWORD, FALSE, TRUE},
        ntdef::NULL,
    },
    um::{
        minwinbase::STILL_ACTIVE,
        processthreadsapi::{GetExitCodeProcess, GetProcessId, TerminateProcess},
        winnt::HANDLE,
    },
};

pub const NO_SESSION: DWORD = 0xFFFFFFFF;

/// How often the service asks the child about its registration.
const STATUS_INTERVAL: Duration = Duration::from_secs(60);
/// A child that has not been registered for this long, with no sessions,
/// is restarted. Covers a child started before the network was usable
/// (boot) or stuck after a network change; RDP reconnects did the same by
/// accident.
const UNREGISTERED_RESTART_AFTER: Duration = Duration::from_secs(5 * 60);

static LAUNCH_FAILURES: AtomicU32 = AtomicU32::new(0);

fn sid_str(sid: DWORD) -> String {
    if sid == NO_SESSION {
        "none".to_owned()
    } else {
        sid.to_string()
    }
}

/// Session ids the service chooses from.
pub fn sessions() -> String {
    let share_rdp = is_share_rdp();
    let console = unsafe { get_current_session(FALSE) };
    let active = unsafe { get_current_session(if share_rdp { TRUE } else { FALSE }) };
    let available: Vec<String> = get_available_sessions(false)
        .iter()
        .map(|s| s.sid.to_string())
        .collect();
    format!(
        "share_rdp={} console={} active={} available=[{}]",
        share_rdp,
        sid_str(console),
        sid_str(active),
        available.join(",")
    )
}

/// `launch_server` with a reason and a logged result. NULL on failure, as the
/// service loop expects; a NULL handle is retried on the next tick.
pub async fn launch(session_id: DWORD, close_first: bool, reason: &str) -> HANDLE {
    log_launch_attempt(session_id, reason);
    let res = if session_id == NO_SESSION {
        // No winlogon.exe to take a token from; keep the running child.
        Err(hbb_common::anyhow::anyhow!(
            "no session attached to the console"
        ))
    } else {
        match launch_server(session_id, close_first).await {
            // launch_privileged_process has logged the Windows error.
            Ok(h) if h.is_null() => Err(hbb_common::anyhow::anyhow!(
                "LaunchProcessWin returned no process"
            )),
            res => res,
        }
    };
    match res {
        Ok(h) => {
            log_launch_result(session_id, Ok(unsafe { GetProcessId(h) }));
            h
        }
        Err(e) => {
            log_launch_result(session_id, Err(e));
            NULL
        }
    }
}

fn log_launch_attempt(session_id: DWORD, reason: &str) {
    // A failing launch is retried every service tick; log the first
    // attempt of a series and then about every 30 s.
    let failures = LAUNCH_FAILURES.load(Ordering::SeqCst);
    if failures == 0 || failures % 100 == 0 {
        log::info!(
            "FuntiDesk service: launching --server in session {} (reason: {}; {})",
            sid_str(session_id),
            reason,
            sessions()
        );
    }
}

fn log_launch_result(session_id: DWORD, res: ResultType<u32>) {
    match res {
        Ok(pid) => {
            let failures = LAUNCH_FAILURES.swap(0, Ordering::SeqCst);
            log::info!(
                "FuntiDesk service: --server started, pid {} in session {}{}",
                pid,
                sid_str(session_id),
                if failures > 0 {
                    format!(" after {} failed attempts", failures)
                } else {
                    String::new()
                }
            );
        }
        Err(e) => {
            let failures = LAUNCH_FAILURES.fetch_add(1, Ordering::SeqCst);
            if failures == 0 || failures % 100 == 0 {
                log::error!(
                    "FuntiDesk service: --server did not start in session {} (attempt {}): {}",
                    sid_str(session_id),
                    failures + 1,
                    e
                );
            }
        }
    }
}

pub fn pid(h: HANDLE) -> u32 {
    if h.is_null() {
        0
    } else {
        unsafe { GetProcessId(h) }
    }
}

/// Asks the child to close, as a session change does, and terminates it if
/// it does not, so that the next launch never runs next to it.
pub async fn stop(h: HANDLE) {
    super::send_close_async("").await.ok();
    for _ in 0..30 {
        let mut code: DWORD = 0;
        if unsafe { GetExitCodeProcess(h, &mut code) } == TRUE && code != STILL_ACTIVE {
            return;
        }
        hbb_common::sleep(0.1).await;
    }
    log::warn!(
        "FuntiDesk service: --server pid {} did not close, terminating",
        pid(h)
    );
    if unsafe { TerminateProcess(h, 1) } == FALSE {
        log::error!(
            "FuntiDesk service: TerminateProcess failed: {}",
            std::io::Error::last_os_error()
        );
    }
}

pub fn log_exit(pid: u32, exit_code: DWORD, session_id: DWORD) {
    log::warn!(
        "FuntiDesk service: --server pid {} exited with code {:#x} (session {}), restarting",
        pid,
        exit_code,
        sid_str(session_id)
    );
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Status {
    Registered,
    Unregistered,
    NoIpc,
}

/// Registration of the child on the rendezvous server, as the service sees it.
pub struct Health {
    last_check: Instant,
    last: Option<Status>,
    unregistered_since: Option<Instant>,
}

impl Health {
    pub fn new() -> Self {
        // A new child gets a full interval before the first question.
        Self {
            last_check: Instant::now(),
            last: None,
            unregistered_since: None,
        }
    }

    /// A new child: its registration starts from scratch.
    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// Returns true when the child should be restarted.
    pub async fn check(&mut self) -> bool {
        if self.last_check.elapsed() < STATUS_INTERVAL {
            return false;
        }
        self.last_check = Instant::now();
        let status = match query_online().await {
            Ok((latency, _)) if latency > 0 => Status::Registered,
            Ok(_) => Status::Unregistered,
            Err(e) => {
                if self.last != Some(Status::NoIpc) {
                    log::warn!("FuntiDesk service: no IPC answer from --server: {}", e);
                }
                Status::NoIpc
            }
        };
        if self.last != Some(status) {
            log::info!(
                "FuntiDesk service: --server rendezvous status {:?} -> {:?}",
                self.last,
                status
            );
        }
        self.last = Some(status);
        if status == Status::Registered {
            self.unregistered_since = None;
            return false;
        }
        let since = *self.unregistered_since.get_or_insert_with(Instant::now);
        if since.elapsed() < UNREGISTERED_RESTART_AFTER {
            return false;
        }
        // Never drop a session that still works (LAN or an existing relay).
        if status == Status::Unregistered {
            match video_conn_count().await {
                Ok(0) => {}
                Ok(n) => {
                    log::info!(
                        "FuntiDesk service: --server unregistered but serves {} sessions, not restarting",
                        n
                    );
                    return false;
                }
                Err(_) => return false,
            }
        }
        log::warn!(
            "FuntiDesk service: --server {:?} for {} s, restarting it",
            status,
            since.elapsed().as_secs()
        );
        self.unregistered_since = None;
        true
    }
}

async fn query_online() -> ResultType<(i64, bool)> {
    let mut c = ipc::connect(1000, "").await?;
    c.send(&ipc::Data::OnlineStatus(None)).await?;
    if let Some(ipc::Data::OnlineStatus(Some(v))) = c.next_timeout(1000).await? {
        return Ok(v);
    }
    hbb_common::bail!("no OnlineStatus reply")
}

async fn video_conn_count() -> ResultType<usize> {
    let mut c = ipc::connect(1000, "").await?;
    c.send(&ipc::Data::VideoConnCount(None)).await?;
    if let Some(ipc::Data::VideoConnCount(Some(n))) = c.next_timeout(1000).await? {
        return Ok(n);
    }
    hbb_common::bail!("no VideoConnCount reply")
}
