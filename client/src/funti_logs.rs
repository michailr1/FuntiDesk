//! FUNTIDESK: the program's own log as one archive — for the person who
//! helps when something does not work. On this computer it is saved where
//! the user chooses; from the workplace it comes over the service
//! connection (ADR-024) with the log of the FuntiDesk service there.

mod select;

use hbb_common::config::Config;
use select::Candidate;
use std::{
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

fn walk(dir: &Path, prefix: &str, depth: u32, out: &mut Vec<(Candidate, PathBuf)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let path = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        let Ok(meta) = e.metadata() else { continue };
        if meta.is_dir() {
            if depth > 0 {
                walk(&path, &format!("{prefix}{name}/"), depth - 1, out);
            }
        } else if select::is_log(&name) {
            let modified = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_secs());
            out.push((Candidate { name: format!("{prefix}{name}"), size: meta.len(), modified }, path));
        }
    }
}

/// Where logs of this computer may be: this process's own, and on Windows
/// the service's (readable only with the rights to it).
fn dirs() -> Vec<(String, PathBuf)> {
    let mut out = vec![("".to_owned(), Config::log_path())];
    #[cfg(windows)]
    {
        let app = hbb_common::config::APP_NAME.read().unwrap().clone();
        let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
        for (label, base) in [
            ("service/", format!("{root}\\ServiceProfiles\\LocalService\\AppData\\Roaming\\{app}\\log")),
            ("system/", format!("{root}\\System32\\config\\systemprofile\\AppData\\Roaming\\{app}\\log")),
        ] {
            let p = PathBuf::from(base);
            if p != out[0].1 {
                out.push((label.to_owned(), p));
            }
        }
    }
    out
}

/// The archive (zip) of the newest logs.
pub fn archive() -> std::io::Result<Vec<u8>> {
    let mut found = Vec::new();
    for (prefix, dir) in dirs() {
        walk(&dir, &prefix, 2, &mut found);
    }
    let chosen = select::choose(found.iter().map(|(c, _)| c.clone()).collect());
    let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = zip::write::FileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for (name, take) in chosen {
        let Some((_, path)) = found.iter().find(|(c, _)| c.name == name) else { continue };
        let Ok(mut file) = std::fs::File::open(path) else { continue };
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        file.seek(SeekFrom::Start(len.saturating_sub(take))).ok();
        let mut data = Vec::new();
        file.take(take).read_to_end(&mut data).ok();
        zip.start_file(name, options).map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        zip.write_all(&data)?;
    }
    let cursor = zip.finish().map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    Ok(cursor.into_inner())
}

/// Saves the archive at `path`; empty on success, else the error text.
pub fn save(path: &str) -> String {
    match archive().and_then(|data| std::fs::write(path, data)) {
        Ok(()) => String::new(),
        Err(e) => e.to_string(),
    }
}
