from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "client/libs/hbb_common/src/config.rs"
WINDOWS = ROOT / "client/src/platform/windows.rs"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


config = CONFIG.read_text(encoding="utf-8")

old_load = '''    pub fn load(id: &str) -> PeerConfig {
        let _lock = CONFIG.read().unwrap();
        match confy::load_path(Self::path(id)) {
'''
new_load = '''    pub fn load(id: &str) -> PeerConfig {
        let _lock = CONFIG.read().unwrap();
        let path = Self::path(id);
        let legacy_path = Self::path_for_app(LEGACY_APP_NAME, id);
        let load_path = if path.exists() {
            path
        } else if legacy_path.exists()
            && fs::symlink_metadata(&legacy_path)
                .map(|metadata| metadata.file_type().is_file())
                .unwrap_or(false)
        {
            if let Some(parent) = path.parent() {
                if let Err(err) = fs::create_dir_all(parent) {
                    log::warn!(
                        "Failed to create FuntiDesk peer directory '{}': {}",
                        parent.display(),
                        err
                    );
                    legacy_path
                } else {
                    match fs::copy(&legacy_path, &path) {
                        Ok(_) => {
                            log::info!(
                                "Migrated legacy peer config '{}' to '{}'",
                                legacy_path.display(),
                                path.display()
                            );
                            path
                        }
                        Err(err) => {
                            log::warn!(
                                "Failed to migrate legacy peer config '{}' to '{}': {}",
                                legacy_path.display(),
                                path.display(),
                                err
                            );
                            legacy_path
                        }
                    }
                }
            } else {
                legacy_path
            }
        } else {
            path
        };
        match confy::load_path(load_path) {
'''
config = replace_once(config, old_load, new_load, "PeerConfig::load")

old_path = '''    fn path(id: &str) -> PathBuf {
        //If the id contains invalid chars, encode it
        let forbidden_paths = Regex::new(r".*[<>:/\\\\|\\?\\*].*");
        let path: PathBuf;
        if let Ok(forbidden_paths) = forbidden_paths {
            let id_encoded = if forbidden_paths.is_match(id) {
                "base64_".to_string() + base64::encode(id, base64::Variant::Original).as_str()
            } else {
                id.to_string()
            };
            path = [PEERS, id_encoded.as_str()].iter().collect();
        } else {
            log::warn!("Regex create failed: {:?}", forbidden_paths.err());
            // fallback for failing to create this regex.
            path = [PEERS, id.replace(":", "_").as_str()].iter().collect();
        }
        Config::with_extension(Config::path(path))
    }
'''
new_path = '''    fn path(id: &str) -> PathBuf {
        let app_name = APP_NAME.read().unwrap().clone();
        Self::path_for_app(&app_name, id)
    }

    fn path_for_app(app_name: &str, id: &str) -> PathBuf {
        // If the id contains invalid chars, encode it.
        let forbidden_paths = Regex::new(r".*[<>:/\\\\|\\?\\*].*");
        let path: PathBuf;
        if let Ok(forbidden_paths) = forbidden_paths {
            let id_encoded = if forbidden_paths.is_match(id) {
                "base64_".to_string() + base64::encode(id, base64::Variant::Original).as_str()
            } else {
                id.to_string()
            };
            path = [PEERS, id_encoded.as_str()].iter().collect();
        } else {
            log::warn!("Regex create failed: {:?}", forbidden_paths.err());
            path = [PEERS, id.replace(":", "_").as_str()].iter().collect();
        }
        Config::with_extension(Config::path_for_app(app_name, path))
    }

    fn migrate_legacy_peers() {
        let app_name = APP_NAME.read().unwrap().clone();
        if app_name == LEGACY_APP_NAME {
            return;
        }
        let legacy_dir = Config::path_for_app(LEGACY_APP_NAME, PEERS);
        let target_dir = Config::path_for_app(&app_name, PEERS);
        let Ok(entries) = fs::read_dir(&legacy_dir) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if !file_type.is_file() {
                continue;
            }
            let source = entry.path();
            if source.extension().and_then(|ext| ext.to_str()) != Some("toml") {
                continue;
            }
            let target = target_dir.join(entry.file_name());
            if target.exists() {
                continue;
            }
            if let Err(err) = fs::create_dir_all(&target_dir) {
                log::warn!(
                    "Failed to create FuntiDesk peer directory '{}': {}",
                    target_dir.display(),
                    err
                );
                return;
            }
            match fs::copy(&source, &target) {
                Ok(_) => log::info!(
                    "Migrated legacy peer config '{}' to '{}'",
                    source.display(),
                    target.display()
                ),
                Err(err) => log::warn!(
                    "Failed to migrate legacy peer config '{}' to '{}': {}",
                    source.display(),
                    target.display(),
                    err
                ),
            }
        }
    }
'''
config = replace_once(config, old_path, new_path, "PeerConfig::path")

old_list = '''    pub fn get_vec_id_modified_time_path(
        id_filters: &Option<Vec<String>>,
    ) -> Vec<(String, SystemTime, PathBuf)> {
        if let Ok(peers) = Config::path(PEERS).read_dir() {
'''
new_list = '''    pub fn get_vec_id_modified_time_path(
        id_filters: &Option<Vec<String>>,
    ) -> Vec<(String, SystemTime, PathBuf)> {
        Self::migrate_legacy_peers();
        if let Ok(peers) = Config::path(PEERS).read_dir() {
'''
config = replace_once(config, old_list, new_list, "peer listing migration")

old_test = '''    fn test_config_files_use_explicit_app_names() {
        let funtidesk_file = Config::file_for_app(FUNTIDESK_APP_NAME, "2");
        let legacy_file = Config::file_for_app(LEGACY_APP_NAME, "2");

        assert_eq!(
            funtidesk_file.file_name().and_then(|name| name.to_str()),
            Some("FuntiDesk2.toml")
        );
        assert_eq!(
            legacy_file.file_name().and_then(|name| name.to_str()),
            Some("RustDesk2.toml")
        );
        assert_ne!(funtidesk_file, legacy_file);
        assert_eq!(Config::file_("2"), funtidesk_file);
    }
'''
new_test = old_test + '''
    #[test]
    fn test_peer_files_use_explicit_app_names() {
        let funtidesk_file = PeerConfig::path_for_app(FUNTIDESK_APP_NAME, "123456789");
        let legacy_file = PeerConfig::path_for_app(LEGACY_APP_NAME, "123456789");
        assert_eq!(
            funtidesk_file.file_name().and_then(|name| name.to_str()),
            Some("123456789.toml")
        );
        assert_ne!(funtidesk_file, legacy_file);
        assert_eq!(PeerConfig::path("123456789"), funtidesk_file);
    }
'''
config = replace_once(config, old_test, new_test, "peer path test")
CONFIG.write_text(config, encoding="utf-8")

windows = WINDOWS.read_text(encoding="utf-8")
windows = replace_once(
    windows,
    '.join("RustDesk")\n        .join("RustDeskCustomClientStaging")',
    '.join("FuntiDesk")\n        .join("FuntiDeskCustomClientStaging")',
    "custom client staging",
)
windows = replace_once(windows, 'let caption = "RustDesk Output"', 'let caption = "FuntiDesk Output"', "message caption")
windows = replace_once(windows, '.join("rustdesk-sciter");\n    let dst = dir.join("rustdesk.exe");', '.join("FuntiDesk-sciter");\n    let dst = dir.join("FuntiDesk.exe");', "portable helper path")
WINDOWS.write_text(windows, encoding="utf-8")

print("FUNTIDESK_PHASE2_PATCH_OK=true")
