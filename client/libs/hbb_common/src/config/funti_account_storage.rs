//! FUNTIDESK (ADR-009/010): a removal and its cursor must reach disk together.

use super::Config2;
use anyhow::{anyhow, Result};
use std::{fs, io::Write, os::windows::ffi::OsStrExt, path::Path};

pub(super) fn store(path: &Path, config: &Config2) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("invalid account storage path"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".funti-account-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(toml::to_string(config)?.as_bytes())?;
        file.sync_all()?;
        drop(file);
        let source: Vec<u16> = temporary.as_os_str().encode_wide().chain(Some(0)).collect();
        let target: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        // Same-directory replacement, including the Windows flush guarantee.
        if unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), 0x1 | 0x8) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

#[link(name = "kernel32")]
extern "system" {
    fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacement_keeps_family_and_marker_in_one_document() {
        let dir = std::env::temp_dir().join(format!("funti-account-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        fs::write(&path, "old document").unwrap();
        let mut config = Config2::default();
        config.options.insert("funti-family".into(), "[]".into());
        config
            .options
            .insert("funti-account-state-v1".into(), "durable-marker".into());
        store(&path, &config).unwrap();
        let actual: Config2 = toml::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(actual.options, config.options);
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        fs::remove_dir_all(dir).unwrap();
    }
}
