//! FUNTIDESK (ADR-024, stage 7): runs a command or script as the FuntiDesk
//! service runs (SYSTEM), without a window, with a time limit; the output
//! is kept up to a limit.

use super::run_rules::{self as rules, Request, Shell};
use hbb_common::base64::{engine::general_purpose::STANDARD, Engine};
use std::{
    io::Read,
    os::windows::process::CommandExt,
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// (answer, journal target).
pub fn run(r: &Request) -> (String, String) {
    let mut temp = None;
    let mut command = match r.shell {
        Shell::PowerShell => {
            let mut c = Command::new("powershell.exe");
            c.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand"])
                .arg(STANDARD.encode(rules::powershell_utf16(&r.script)));
            c
        }
        Shell::Cmd => {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos());
            let path = std::env::temp_dir().join(format!("funtidesk-run-{}-{}.cmd", std::process::id(), nanos));
            if std::fs::write(&path, rules::cmd_file(&r.script)).is_err() {
                return failed(r);
            }
            let mut c = Command::new("cmd.exe");
            c.args(["/D", "/C"]).arg(&path);
            temp = Some(path);
            c
        }
    };
    let child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
    let result = match child {
        Ok(child) => wait(child, r),
        Err(e) => {
            hbb_common::log::info!("FuntiDesk run: {}", e);
            failed(r)
        }
    };
    if let Some(path) = temp {
        std::fs::remove_file(path).ok();
    }
    result
}

fn failed(r: &Request) -> (String, String) {
    (
        super::rules::error_json("run", "funti-run-failed")
            .as_object()
            .cloned()
            .map(|mut m| {
                m.insert("id".into(), r.id.clone().into());
                serde_json::Value::Object(m).to_string()
            })
            .unwrap_or_default(),
        rules::journal_target(r, None, false),
    )
}

fn reader(mut pipe: impl Read + Send + 'static, out: Arc<Mutex<(Vec<u8>, bool)>>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let mut buffer = [0u8; 8192];
        while let Ok(n) = pipe.read(&mut buffer) {
            if n == 0 {
                break;
            }
            let mut o = out.lock().unwrap();
            let cut = rules::append_capped(&mut o.0, &buffer[..n]);
            o.1 |= cut;
        }
    })
}

fn wait(mut child: Child, r: &Request) -> (String, String) {
    let out = Arc::new(Mutex::new((Vec::new(), false)));
    let readers: Vec<_> = [
        child.stdout.take().map(|p| reader(p, out.clone())),
        child.stderr.take().map(|p| reader(p, out.clone())),
    ]
    .into_iter()
    .flatten()
    .collect();
    let deadline = Instant::now() + Duration::from_secs(r.timeout);
    let mut timed_out = false;
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                timed_out = true;
                // The whole tree: a script may have started other programs.
                Command::new("taskkill.exe")
                    .args(["/T", "/F", "/PID", &child.id().to_string()])
                    .creation_flags(CREATE_NO_WINDOW)
                    .output()
                    .ok();
                child.kill().ok();
                child.wait().ok();
                break None;
            }
        }
    };
    for t in readers {
        t.join().ok();
    }
    let o = out.lock().unwrap();
    (
        rules::answer_json(r, code, &o.0, o.1, timed_out).to_string(),
        rules::journal_target(r, code, timed_out),
    )
}
