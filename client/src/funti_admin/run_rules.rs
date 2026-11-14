//! FUNTIDESK (ADR-024, stage 7): a command or script run on a computer from
//! the workplace — the request, the limits, the answer and the journal text.
//! Only std and serde_json here, so this file is also built and tested on
//! its own.

use serde_json::{json, Value};

pub const SCRIPT_MAX: usize = 32 * 1024;
pub const OUTPUT_MAX: usize = 64 * 1024;
const TIMEOUT_DEFAULT: u64 = 60;
const TIMEOUT_MIN: u64 = 5;
pub const TIMEOUT_MAX: u64 = 600;
/// The journal keeps the beginning of the script.
const JOURNAL_SCRIPT: usize = 300;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Shell {
    PowerShell,
    Cmd,
}

impl Shell {
    pub fn id(self) -> &'static str {
        match self {
            Shell::PowerShell => "powershell",
            Shell::Cmd => "cmd",
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct Request {
    /// Chosen by the window, sent back with the answer.
    pub id: String,
    pub shell: Shell,
    pub script: String,
    pub timeout: u64,
    /// In the session of the signed-in user, with their drives and
    /// settings, instead of as the system.
    pub as_user: bool,
}

/// `{"op":"run","id":"…","shell":"powershell","script":"…","timeout":60}`;
/// Err(translation key) for a request that cannot run.
pub fn parse_request(v: &Value) -> Result<Request, &'static str> {
    let shell = match v["shell"].as_str().unwrap_or("powershell") {
        "powershell" => Shell::PowerShell,
        "cmd" => Shell::Cmd,
        _ => return Err("funti-admin-bad-request"),
    };
    let script = v["script"].as_str().unwrap_or("");
    if script.trim().is_empty() {
        return Err("funti-admin-bad-request");
    }
    if script.len() > SCRIPT_MAX {
        return Err("funti-run-too-long");
    }
    Ok(Request {
        id: v["id"].as_str().unwrap_or("").chars().take(64).collect(),
        shell,
        script: script.to_owned(),
        timeout: v["timeout"].as_u64().unwrap_or(TIMEOUT_DEFAULT).clamp(TIMEOUT_MIN, TIMEOUT_MAX),
        as_user: v["asUser"] == true,
    })
}

/// The script as PowerShell's -EncodedCommand wants it: UTF-16LE, and
/// output in UTF-8 so that Russian text arrives intact.
pub fn powershell_utf16(script: &str) -> Vec<u8> {
    let full = format!("[Console]::OutputEncoding = [Text.Encoding]::UTF8\n$ProgressPreference = 'SilentlyContinue'\n{script}");
    full.encode_utf16().flat_map(|u| u.to_le_bytes()).collect()
}

/// A cmd script file: UTF-8 code page first, Windows line ends.
pub fn cmd_file(script: &str) -> String {
    let body = script.replace("\r\n", "\n").replace('\n', "\r\n");
    format!("@echo off\r\nchcp 65001 >nul\r\n{body}\r\n")
}

/// The batch file that runs the command in the user's session and leaves
/// its output and exit code next to itself: `line` is the command,
/// `out` and `code` the files to write.
pub fn user_wrapper(line: &str, out: &str, code: &str) -> String {
    format!("@echo off\r\nchcp 65001 >nul\r\n{line} > \"{out}\" 2>&1\r\necho %errorlevel% > \"{code}\"\r\n")
}

/// The exit code the wrapper wrote; None while it is not there yet.
pub fn parse_code(text: &str) -> Option<i32> {
    text.trim().parse().ok()
}

/// Appends `more` to `out` up to OUTPUT_MAX bytes; true if something was cut.
pub fn append_capped(out: &mut Vec<u8>, more: &[u8]) -> bool {
    let room = OUTPUT_MAX.saturating_sub(out.len());
    out.extend_from_slice(&more[..more.len().min(room)]);
    more.len() > room
}

pub fn answer_json(r: &Request, code: Option<i32>, output: &[u8], cut: bool, timed_out: bool) -> Value {
    json!({
        "op": "run",
        "id": r.id,
        "code": code,
        "output": String::from_utf8_lossy(output),
        "cut": cut,
        "timedOut": timed_out,
    })
}

/// "powershell, code 0: Get-Service …" for the journal of that computer.
pub fn journal_target(r: &Request, code: Option<i32>, timed_out: bool) -> String {
    let script: String = r.script.trim().chars().take(JOURNAL_SCRIPT).collect();
    let end = if timed_out {
        "timeout".to_owned()
    } else {
        code.map_or("?".to_owned(), |c| c.to_string())
    };
    format!("{} [{}]: {}", r.shell.id(), end, script)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests() {
        let r = parse_request(&json!({"op": "run", "id": "7", "script": "hostname"})).unwrap();
        assert_eq!((r.shell, r.timeout, r.id.as_str()), (Shell::PowerShell, TIMEOUT_DEFAULT, "7"));
        let r = parse_request(&json!({"op": "run", "shell": "cmd", "script": "ver", "timeout": 99999})).unwrap();
        assert_eq!((r.shell, r.timeout), (Shell::Cmd, TIMEOUT_MAX));
        assert_eq!(parse_request(&json!({"op": "run", "script": "  "})), Err("funti-admin-bad-request"));
        assert_eq!(parse_request(&json!({"op": "run", "shell": "bash", "script": "ls"})), Err("funti-admin-bad-request"));
        let long = "x".repeat(SCRIPT_MAX + 1);
        assert_eq!(parse_request(&json!({"op": "run", "script": long})), Err("funti-run-too-long"));
    }

    #[test]
    fn encodings() {
        let b = powershell_utf16("Write-Output 'я'");
        assert_eq!(b.len() % 2, 0);
        assert!(b.ends_with(&[0x4F, 0x04, b'\'', 0])); // "я" is U+044F
        assert_eq!(cmd_file("a\nb"), "@echo off\r\nchcp 65001 >nul\r\na\r\nb\r\n");
    }

    #[test]
    fn user_session() {
        let r = parse_request(&json!({"op": "run", "script": "net use", "asUser": true})).unwrap();
        assert!(r.as_user);
        assert!(!parse_request(&json!({"op": "run", "script": "x"})).unwrap().as_user);
        let w = user_wrapper("call \"C:\\t\\s.cmd\"", "C:\\t\\out.txt", "C:\\t\\code.txt");
        assert!(w.starts_with("@echo off\r\nchcp 65001 >nul\r\ncall "));
        assert!(w.contains("> \"C:\\t\\out.txt\" 2>&1\r\n"));
        assert!(w.ends_with("echo %errorlevel% > \"C:\\t\\code.txt\"\r\n"));
        assert_eq!(parse_code(" 3 \r\n"), Some(3));
        assert_eq!(parse_code(""), None);
    }

    #[test]
    fn output_limit() {
        let mut out = Vec::new();
        assert!(!append_capped(&mut out, &vec![b'a'; OUTPUT_MAX - 1]));
        assert!(append_capped(&mut out, b"bc"));
        assert_eq!(out.len(), OUTPUT_MAX);
        assert!(append_capped(&mut out, b"d"));
        assert_eq!(out.len(), OUTPUT_MAX);
    }

    #[test]
    fn journal() {
        let r = parse_request(&json!({"op": "run", "script": "  Get-Service\n"})).unwrap();
        assert_eq!(journal_target(&r, Some(0), false), "powershell [0]: Get-Service");
        assert_eq!(journal_target(&r, None, true), "powershell [timeout]: Get-Service");
        let long = parse_request(&json!({"op": "run", "script": "я".repeat(1000)})).unwrap();
        assert_eq!(journal_target(&long, Some(1), false).chars().count(), "powershell [1]: ".len() + JOURNAL_SCRIPT);
    }

    #[test]
    fn answer() {
        let r = parse_request(&json!({"op": "run", "id": "a", "script": "x"})).unwrap();
        let a = answer_json(&r, Some(3), "вывод".as_bytes(), false, false);
        assert_eq!((a["id"].as_str(), a["code"].as_i64(), a["output"].as_str()), (Some("a"), Some(3), Some("вывод")));
    }
}
