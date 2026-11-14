//! FUNTIDESK (ADR-024, stage 5): what takes the space of a disk — the
//! folders of one level with their sizes, largest first; the window goes
//! deeper by asking again for a folder. Only std and serde_json here, so
//! this file is also built and tested on its own.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A whole system disk may take minutes; what is counted by then is shown,
/// marked as not complete.
pub const TIME_LIMIT: Duration = Duration::from_secs(120);
const SHOWN: usize = 40;

/// `{"op":"folders","path":"C:\\Users"}`; empty: the system disk.
pub fn parse_path(v: &Value, system_disk: &str) -> PathBuf {
    match v["path"].as_str().map(str::trim).filter(|p| !p.is_empty()) {
        Some(p) => PathBuf::from(p),
        None => PathBuf::from(system_disk),
    }
}

/// Size of everything under `dir`, not following links; false if the time
/// ran out on the way.
fn size(dir: &Path, deadline: Instant) -> (u64, bool) {
    let mut total = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        if Instant::now() > deadline {
            return (total, false);
        }
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let Ok(meta) = e.path().symlink_metadata() else { continue };
            if meta.file_type().is_symlink() {
                continue;
            }
            if meta.is_dir() {
                stack.push(e.path());
            } else {
                total += meta.len();
            }
        }
    }
    (total, true)
}

pub fn scan(dir: &Path, limit: Duration) -> Value {
    let deadline = Instant::now() + limit;
    let mut folders = Vec::new();
    let mut files = 0u64;
    let mut complete = true;
    match std::fs::read_dir(dir) {
        Ok(entries) => {
            for e in entries.flatten() {
                let Ok(meta) = e.path().symlink_metadata() else { continue };
                if meta.file_type().is_symlink() {
                    continue;
                }
                if meta.is_dir() {
                    let (bytes, done) = size(&e.path(), deadline);
                    complete &= done;
                    folders.push((e.file_name().to_string_lossy().into_owned(), bytes));
                } else {
                    files += meta.len();
                }
            }
        }
        Err(_) => return json!({"op": "folders", "path": dir.to_string_lossy(), "error": "funti-folders-unreadable"}),
    }
    folders.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let total: u64 = files + folders.iter().map(|f| f.1).sum::<u64>();
    folders.truncate(SHOWN);
    json!({
        "op": "folders",
        "path": dir.to_string_lossy(),
        "complete": complete,
        "total": total,
        "files": files,
        "folders": folders.iter().map(|(name, bytes)| json!({"name": name, "size": bytes})).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes() {
        let root = std::env::temp_dir().join(format!("funti-folders-{}", std::process::id()));
        std::fs::create_dir_all(root.join("big/inner")).unwrap();
        std::fs::create_dir_all(root.join("small")).unwrap();
        std::fs::write(root.join("big/a.bin"), vec![0u8; 3000]).unwrap();
        std::fs::write(root.join("big/inner/b.bin"), vec![0u8; 2000]).unwrap();
        std::fs::write(root.join("small/c.bin"), vec![0u8; 10]).unwrap();
        std::fs::write(root.join("top.txt"), vec![0u8; 7]).unwrap();
        let v = scan(&root, Duration::from_secs(10));
        assert_eq!(v["folders"][0]["name"], "big");
        assert_eq!(v["folders"][0]["size"], 5000);
        assert_eq!(v["folders"][1]["size"], 10);
        assert_eq!((v["files"].as_u64(), v["total"].as_u64(), v["complete"].as_bool()), (Some(7), Some(5017), Some(true)));
        let none = scan(&root.join("missing"), Duration::from_secs(1));
        assert_eq!(none["error"], "funti-folders-unreadable");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn paths() {
        assert_eq!(parse_path(&json!({}), "C:\\"), PathBuf::from("C:\\"));
        assert_eq!(parse_path(&json!({"path": " D:\\Data "}), "C:\\"), PathBuf::from("D:\\Data"));
    }
}
