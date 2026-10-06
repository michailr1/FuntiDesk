from pathlib import Path

p = Path('client/libs/hbb_common/src/config.rs')
s = p.read_text(encoding='utf-8')
old = '''    fn copy_legacy_config_file(legacy_file: &Path, file: &Path) -> std::io::Result<()> {
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(legacy_file, file)?;
        Ok(())
    }
'''
new = '''    fn copy_legacy_config_file(legacy_file: &Path, file: &Path) -> std::io::Result<()> {
        let metadata = fs::symlink_metadata(legacy_file)?;
        if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "legacy config source is not a regular file",
            ));
        }
        #[cfg(target_os = "windows")]
        {
            use std::os::windows::fs::MetadataExt;
            const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
            if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "legacy config source is a reparse point",
                ));
            }
        }
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut input = fs::File::open(legacy_file)?;
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(file)?;
        if let Err(err) = std::io::copy(&mut input, &mut output) {
            drop(output);
            let _ = fs::remove_file(file);
            return Err(err);
        }
        let _ = fs::set_permissions(file, metadata.permissions());
        Ok(())
    }
'''
count = s.count(old)
if count != 1:
    raise SystemExit(f'config migration precondition failed: expected 1 match, found {count}')
s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')
print('FUNTIDESK_CONFIG_MIGRATION_HARDENING_OK=true')
