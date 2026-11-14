//! FUNTIDESK (ADR-024, stage 7): a command on Linux — /bin/sh as the
//! FuntiDesk service runs, with a time limit (the process group is ended at
//! the limit) and the output kept up to a limit.

use super::run_rules::{self as rules, Request};
use std::{
    io::Read,
    os::unix::process::CommandExt,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

fn failed(r: &Request, error: &str) -> (String, String) {
    let mut answer = super::rules::error_json("run", error);
    answer["id"] = r.id.clone().into();
    (answer.to_string(), rules::journal_target(r, None, false))
}

pub fn run(r: &Request) -> (String, String) {
    if !rules::shell_here(r.shell, false) {
        return failed(r, "funti-run-wrong-shell");
    }
    if r.as_user {
        return failed(r, "funti-run-as-user-windows");
    }
    let child = Command::new("/bin/sh")
        .arg("-c")
        .arg(&r.script)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group, so that the whole group can be ended.
        .process_group(0)
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(_) => return failed(r, "funti-run-failed"),
    };
    let out = Arc::new(Mutex::new((Vec::new(), false)));
    let mut readers = Vec::new();
    for pipe in [
        child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>),
        child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let out = out.clone();
        readers.push(std::thread::spawn(move || {
            let mut pipe = pipe;
            let mut buffer = [0u8; 8192];
            while let Ok(n) = pipe.read(&mut buffer) {
                if n == 0 {
                    break;
                }
                let mut o = out.lock().unwrap();
                let cut = rules::append_capped(&mut o.0, &buffer[..n]);
                o.1 |= cut;
            }
        }));
    }
    let deadline = Instant::now() + Duration::from_secs(r.timeout);
    let mut timed_out = false;
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                timed_out = true;
                Command::new("kill").args(["-KILL", &format!("-{}", child.id())]).output().ok();
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
