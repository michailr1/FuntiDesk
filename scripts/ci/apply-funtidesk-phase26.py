from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "client/src/plugin/mod.rs"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


text = PLUGIN.read_text(encoding="utf-8")
text = replace_once(
    text,
    '''use std::{
    ffi::{c_char, c_int, c_void, CStr},
    path::PathBuf,
    ptr::null,
};
''',
    '''use std::{
    ffi::{c_char, c_int, c_void, CStr},
    fs,
    io,
    path::{Path, PathBuf},
    ptr::null,
};
''',
    "plugin std imports",
)

old = '''#[inline]
fn get_plugins_dir() -> ResultType<PathBuf> {
    Ok(get_share_dir()?
        .join("RustDesk")
        .join(PLUGIN_SOURCE_LOCAL_DIR))
}
'''
new = '''#[inline]
fn get_plugins_dir_for(app_name: &str) -> ResultType<PathBuf> {
    Ok(get_share_dir()?.join(app_name).join(PLUGIN_SOURCE_LOCAL_DIR))
}

fn copy_plugin_file_missing(source: &Path, target: &Path) -> ResultType<()> {
    let mut input = fs::File::open(source)?;
    let mut output = match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
    {
        Ok(output) => output,
        Err(err) if err.kind() == io::ErrorKind::AlreadyExists => return Ok(()),
        Err(err) => return Err(err.into()),
    };

    if let Err(err) = io::copy(&mut input, &mut output) {
        drop(output);
        let _ = fs::remove_file(target);
        return Err(err.into());
    }
    if let Ok(metadata) = input.metadata() {
        let _ = fs::set_permissions(target, metadata.permissions());
    }
    Ok(())
}

fn copy_plugin_tree_missing(source: &Path, target: &Path) -> ResultType<()> {
    let metadata = fs::symlink_metadata(source)?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_dir() {
        bail!("legacy plugin root is not a regular directory: {:?}", source);
    }

    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let source_path = entry.path();
        let target_path = target.join(entry.file_name());

        if file_type.is_symlink() {
            log::warn!(
                "Skipping symlink/reparse entry during legacy plugin migration: {:?}",
                source_path
            );
            continue;
        }
        if file_type.is_dir() {
            copy_plugin_tree_missing(&source_path, &target_path)?;
        } else if file_type.is_file() {
            copy_plugin_file_missing(&source_path, &target_path)?;
        }
    }
    Ok(())
}

#[inline]
fn get_plugins_dir() -> ResultType<PathBuf> {
    let current = get_plugins_dir_for("FuntiDesk")?;
    let legacy = get_plugins_dir_for("RustDesk")?;

    let legacy_is_dir = fs::symlink_metadata(&legacy)
        .map(|metadata| metadata.file_type().is_dir() && !metadata.file_type().is_symlink())
        .unwrap_or(false);
    if legacy_is_dir {
        match copy_plugin_tree_missing(&legacy, &current) {
            Ok(_) => {
                log::info!(
                    "Migrated missing legacy plugin files from {:?} to {:?}",
                    legacy,
                    current
                );
            }
            Err(err) => {
                log::warn!(
                    "Failed to migrate legacy plugin directory {:?} to {:?}: {}; using legacy directory for this run",
                    legacy,
                    current,
                    err
                );
                return Ok(legacy);
            }
        }
    }
    Ok(current)
}
'''
text = replace_once(text, old, new, "plugin directory namespace")

# Pure path contract: no filesystem mutation and valid on every supported desktop OS.
text += '''

#[cfg(test)]
mod funtidesk_identity_tests {
    use super::*;

    #[test]
    fn plugin_roots_use_separate_product_namespaces() {
        let current = get_plugins_dir_for("FuntiDesk").unwrap();
        let legacy = get_plugins_dir_for("RustDesk").unwrap();
        assert_ne!(current, legacy);
        assert!(current.ends_with(Path::new("FuntiDesk").join(PLUGIN_SOURCE_LOCAL_DIR)));
        assert!(legacy.ends_with(Path::new("RustDesk").join(PLUGIN_SOURCE_LOCAL_DIR)));
    }
}
'''

PLUGIN.write_text(text, encoding="utf-8")
print("FUNTIDESK_PHASE26_PATCH_OK=true")
