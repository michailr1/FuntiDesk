// FUNTIDESK: supervision of the `--server` child by the Windows service.
//
// Unattended access after a reboot (2026-10-22, MINIPC): the service loop
// (upstream) logged neither why it launched `--server` nor the result, and
// closed a working `--server` to launch into a session that did not exist.
// This module logs every launch with its reason, the sessions chosen from,
// the result and child exits, and skips launches into no session.
// Logs go to the service log (`C:\Windows\ServiceProfiles\LocalService\
// AppData\Roaming\FuntiDesk\log\service`) and are written before sign-in.
// No secrets: session ids, process ids, Windows error codes and states only.

use super::{get_available_sessions, get_current_session, is_share_rdp, launch_server};
use hbb_common::{log, ResultType};
use std::sync::atomic::{AtomicU32, Ordering};
use winapi::{
    shared::{
        minwindef::{DWORD, FALSE, TRUE},
        ntdef::NULL,
    },
    um::{processthreadsapi::GetProcessId, winnt::HANDLE},
};

pub const NO_SESSION: DWORD = 0xFFFFFFFF;

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

pub fn log_exit(pid: u32, exit_code: DWORD, session_id: DWORD) {
    log::warn!(
        "FuntiDesk service: --server pid {} exited with code {:#x} (session {}), restarting",
        pid,
        exit_code,
        sid_str(session_id)
    );
}
