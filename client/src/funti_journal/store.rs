//! FUNTIDESK (ADR-020): the journal file. Only std and serde_json here, so
//! this file is also built and tested on its own.

use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
};

/// Text that came from the other side is cut to this many characters.
const TEXT_MAX: usize = 64;

pub struct Store {
    dir: PathBuf,
    max_bytes: u64,
    /// Start time (ms) of each admitted connection, by connection id.
    open: HashMap<i32, i64>,
}

impl Store {
    pub fn new(dir: PathBuf, max_bytes: u64) -> Self {
        Self {
            dir,
            max_bytes,
            open: HashMap::new(),
        }
    }

    fn current(&self) -> PathBuf {
        self.dir.join("funti-journal.jsonl")
    }

    fn previous(&self) -> PathBuf {
        self.dir.join("funti-journal.1.jsonl")
    }

    /// One event per line. When the file is full it becomes the "previous"
    /// one (replacing the older previous), so the journal takes at most
    /// twice `max_bytes`.
    pub fn append(&self, event: &Value) -> std::io::Result<()> {
        let mut line = event.to_string();
        line.push('\n');
        let size = fs::metadata(self.current()).map(|m| m.len()).unwrap_or(0);
        if size > 0 && size + line.len() as u64 > self.max_bytes {
            fs::rename(self.current(), self.previous())?;
        }
        let mut options = OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(self.current())?.write_all(line.as_bytes())
    }

    /// The newest `limit` events, newest first. Broken lines are skipped.
    pub fn read(&self, limit: usize) -> Vec<Value> {
        let mut events = Vec::new();
        for path in [self.current(), self.previous()] {
            let text = fs::read_to_string(path).unwrap_or_default();
            for line in text.lines().rev() {
                if events.len() == limit {
                    return events;
                }
                if let Ok(event) = serde_json::from_str(line) {
                    events.push(event);
                }
            }
        }
        events
    }

    /// A connection that passed authorization.
    pub fn connected(&mut self, now_ms: i64, conn: i32, ip: &str, audit: &Value) -> Value {
        self.open.insert(conn, now_ms);
        let mut event = json!({
            "t": now_ms / 1000,
            "kind": "connected",
            "conn": conn,
            "ip": text(ip),
            "peer": text(audit["peer"][0].as_str().unwrap_or_default()),
            "name": text(audit["peer"][1].as_str().unwrap_or_default()),
            "type": audit["type"].as_i64().unwrap_or(0),
        });
        for key in ["primary_auth", "two_factor"] {
            if let Some(n) = audit[key].as_i64() {
                event[key] = json!(n);
            }
        }
        event
    }

    /// The end of an admitted connection; `None` for one that never got in.
    pub fn closed(&mut self, now_ms: i64, conn: i32) -> Option<Value> {
        let start = self.open.remove(&conn)?;
        Some(json!({
            "t": now_ms / 1000,
            "kind": "closed",
            "conn": conn,
            "seconds": ((now_ms - start) / 1000).max(0),
        }))
    }
}

/// Names kept for one transfer: the largest files, as upstream's audit does.
const NAMES_MAX: usize = 10;
/// A file name or folder path is cut to this many characters.
const PATH_MAX: usize = 200;

/// Files sent to this computer (`received`) or taken from it: how many, how
/// large, the folder on this computer and the names of the largest ones.
pub fn files(
    now_ms: i64,
    conn: i32,
    peer: &str,
    ip: &str,
    received: bool,
    path: &str,
    files: &[(String, i64)],
) -> Value {
    let mut largest: Vec<&(String, i64)> = files.iter().filter(|f| !f.0.is_empty()).collect();
    largest.sort_by(|a, b| b.1.cmp(&a.1));
    largest.truncate(NAMES_MAX);
    json!({
        "t": now_ms / 1000,
        "kind": "files",
        "conn": conn,
        "ip": text(ip),
        "peer": text(peer),
        "received": received,
        "num": files.len(),
        "bytes": files.iter().map(|f| f.1.max(0)).sum::<i64>(),
        "path": cut(path, PATH_MAX),
        "names": largest.iter().map(|f| cut(&f.0, PATH_MAX)).collect::<Vec<_>>(),
    })
}

/// A refused attempt. `alarm` is the number of upstream's AlarmAuditType.
pub fn refused(now_ms: i64, conn: i32, alarm: i8, info: &Value) -> Value {
    json!({
        "t": now_ms / 1000,
        "kind": "refused",
        "conn": conn,
        "alarm": alarm,
        "ip": text(&plain(&info["ip"])),
        "peer": text(&plain(&info["id"])),
        "name": text(&plain(&info["name"])),
    })
}

fn plain(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// The other side chooses its id and name: keep them short and printable.
fn text(s: &str) -> String {
    cut(s, TEXT_MAX)
}

fn cut(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).take(max).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str, max: u64) -> Store {
        let dir = std::env::temp_dir().join(format!("funti-journal-{}-{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Store::new(dir, max)
    }

    #[test]
    fn a_session_is_written_and_read_newest_first() {
        let mut s = store("session", 10_000);
        let audit = json!({"peer": ["123456789", "Мама"], "type": 1, "two_factor": 2});
        let opened = s.connected(1_000_000, 7, "203.0.113.5", &audit);
        s.append(&opened).unwrap();
        assert!(s.closed(1_005_000, 8).is_none(), "a connection that never got in");
        let closed = s.closed(1_065_000, 7).unwrap();
        s.append(&closed).unwrap();
        assert!(s.closed(1_070_000, 7).is_none(), "closed only once");

        let events = s.read(10);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["kind"], "closed");
        assert_eq!(events[0]["seconds"], 65);
        assert_eq!(events[1]["kind"], "connected");
        assert_eq!(events[1]["peer"], "123456789");
        assert_eq!(events[1]["name"], "Мама");
        assert_eq!(events[1]["type"], 1);
        assert_eq!(events[1]["two_factor"], 2);
        assert!(events[1].get("primary_auth").is_none());
        assert_eq!(s.read(1).len(), 1);
    }

    #[test]
    fn text_from_the_other_side_is_cut_and_stays_on_one_line() {
        let mut s = store("text", 10_000);
        let name = format!("a\nb\u{1b}[31m{}", "x".repeat(500));
        let event = s.connected(0, 1, "::1", &json!({"peer": ["1\r\n2", name], "type": 0}));
        s.append(&event).unwrap();
        let raw = fs::read_to_string(s.current()).unwrap();
        assert_eq!(raw.lines().count(), 1);
        let back = &s.read(5)[0];
        assert_eq!(back["peer"], "12");
        assert_eq!(back["name"].as_str().unwrap().chars().count(), 64);
        assert!(back["name"].as_str().unwrap().starts_with("ab[31m"));
    }

    #[test]
    fn the_journal_never_grows_past_two_files() {
        let s = store("rotate", 600);
        for n in 0..200 {
            let sent = [("a.txt".to_owned(), 1), ("b.txt".to_owned(), 2)];
            s.append(&files(n * 1000, n as i32, "1", "198.51.100.1", true, "", &sent)).unwrap();
        }
        let current = fs::metadata(s.current()).unwrap().len();
        let previous = fs::metadata(s.previous()).unwrap().len();
        assert!(current <= 600 && previous <= 600, "{current} {previous}");
        let events = s.read(1000);
        assert_eq!(events[0]["conn"], 199);
        assert!(events.windows(2).all(|w| w[0]["conn"].as_i64() > w[1]["conn"].as_i64()));
        assert_eq!(events[0]["bytes"], 3);
        assert_eq!(events[0]["num"], 2);
    }

    #[test]
    fn a_transfer_keeps_the_folder_and_the_ten_largest_names() {
        let mut sent: Vec<(String, i64)> = (1..=25).map(|n| (format!("f{n}.jpg"), n)).collect();
        sent.push((format!("long\n{}", "я".repeat(500)), 1000));
        let e = files(0, 1, "1", "::1", false, "C:\\Users\\Мама\\Фото", &sent);
        assert_eq!(e["num"], 26);
        assert_eq!(e["bytes"], 325 + 1000);
        assert_eq!(e["path"], "C:\\Users\\Мама\\Фото");
        let names = e["names"].as_array().unwrap();
        assert_eq!(names.len(), 10);
        assert_eq!(names[0].as_str().unwrap().chars().count(), 200);
        assert!(names[0].as_str().unwrap().starts_with("longя"));
        assert_eq!(names[1], "f25.jpg");
        assert_eq!(names[9], "f17.jpg");
        // A single file sent by its full path comes with an empty name.
        let e = files(0, 1, "1", "::1", true, "D:\\a.zip", &[(String::new(), 7)]);
        assert_eq!(e["num"], 1);
        assert!(e["names"].as_array().unwrap().is_empty());
    }

    #[test]
    fn broken_lines_and_missing_files_are_skipped() {
        let s = store("broken", 10_000);
        assert!(s.read(10).is_empty());
        fs::write(s.current(), "not json\n{\"kind\":\"closed\"}\n{\"half\":").unwrap();
        assert_eq!(s.read(10).len(), 1);
    }

    #[test]
    fn a_refused_attempt_keeps_what_is_known() {
        let ip: std::net::IpAddr = "192.0.2.9".parse().unwrap();
        let e = refused(5000, 3, 10, &json!({"ip": ip, "id": "987", "name": "X"}));
        assert_eq!(e["ip"], "192.0.2.9");
        assert_eq!(e["peer"], "987");
        assert_eq!(e["alarm"], 10);
        let e = refused(5000, 3, 0, &json!({"ip": "192.0.2.9"}));
        assert_eq!(e["peer"], "");
    }
}
