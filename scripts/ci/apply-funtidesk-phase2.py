from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "client/libs/hbb_common/src/config.rs"
COMMON = ROOT / "client/src/common.rs"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


config = CONFIG.read_text(encoding="utf-8")

old_lan = '''impl LanPeers {
    pub fn load() -> LanPeers {
        let _lock = CONFIG.read().unwrap();
        match confy::load_path(Config::file_("_lan_peers")) {
            Ok(peers) => peers,
            Err(err) => {
                log::error!("Failed to load lan peers: {}", err);
                Default::default()
            }
        }
    }
'''
new_lan = '''impl LanPeers {
    pub fn load() -> LanPeers {
        let _lock = CONFIG.read().unwrap();
        Config::load_::<LanPeers>("_lan_peers")
    }
'''
config = replace_once(config, old_lan, new_lan, "LanPeers::load")

old_lan_mtime = '''    pub fn modify_time() -> crate::ResultType<u64> {
        let p = Config::file_("_lan_peers");
        Ok(fs::metadata(p)?
'''
new_lan_mtime = '''    pub fn modify_time() -> crate::ResultType<u64> {
        let current = Config::file_("_lan_peers");
        let p = if current.exists() {
            current
        } else {
            Config::file_for_app(LEGACY_APP_NAME, "_lan_peers")
        };
        Ok(fs::metadata(p)?
'''
config = replace_once(config, old_lan_mtime, new_lan_mtime, "LanPeers::modify_time")

old_ab_path = '''impl Ab {
    fn path() -> PathBuf {
        let filename = format!("{}_ab", APP_NAME.read().unwrap().clone());
        Config::path(filename)
    }
'''
new_ab_path = '''impl Ab {
    fn path() -> PathBuf {
        let app_name = APP_NAME.read().unwrap().clone();
        Self::path_for_app(&app_name)
    }

    fn path_for_app(app_name: &str) -> PathBuf {
        let filename = format!("{app_name}_ab");
        Config::path_for_app(app_name, filename)
    }

    fn readable_path() -> PathBuf {
        let path = Self::path();
        if path.exists() {
            return path;
        }
        let legacy = Self::path_for_app(LEGACY_APP_NAME);
        if !fs::symlink_metadata(&legacy)
            .map(|metadata| metadata.file_type().is_file())
            .unwrap_or(false)
        {
            return path;
        }
        if let Some(parent) = path.parent() {
            if let Err(err) = fs::create_dir_all(parent) {
                log::warn!("Failed to create FuntiDesk address-book directory: {}", err);
                return legacy;
            }
        }
        match fs::copy(&legacy, &path) {
            Ok(_) => {
                log::info!(
                    "Migrated legacy address book '{}' to '{}'",
                    legacy.display(),
                    path.display()
                );
                path
            }
            Err(err) => {
                log::warn!(
                    "Failed to migrate legacy address book '{}' to '{}': {}",
                    legacy.display(),
                    path.display(),
                    err
                );
                legacy
            }
        }
    }
'''
config = replace_once(config, old_ab_path, new_ab_path, "Ab paths")
config = replace_once(
    config,
    '        if let Ok(mut file) = std::fs::File::open(Self::path()) {\n',
    '        if let Ok(mut file) = std::fs::File::open(Self::readable_path()) {\n',
    "Ab::load path",
)

old_group_path = '''impl Group {
    fn path() -> PathBuf {
        let filename = format!("{}_group", APP_NAME.read().unwrap().clone());
        Config::path(filename)
    }
'''
new_group_path = '''impl Group {
    fn path() -> PathBuf {
        let app_name = APP_NAME.read().unwrap().clone();
        Self::path_for_app(&app_name)
    }

    fn path_for_app(app_name: &str) -> PathBuf {
        let filename = format!("{app_name}_group");
        Config::path_for_app(app_name, filename)
    }

    fn readable_path() -> PathBuf {
        let path = Self::path();
        if path.exists() {
            return path;
        }
        let legacy = Self::path_for_app(LEGACY_APP_NAME);
        if !fs::symlink_metadata(&legacy)
            .map(|metadata| metadata.file_type().is_file())
            .unwrap_or(false)
        {
            return path;
        }
        if let Some(parent) = path.parent() {
            if let Err(err) = fs::create_dir_all(parent) {
                log::warn!("Failed to create FuntiDesk group directory: {}", err);
                return legacy;
            }
        }
        match fs::copy(&legacy, &path) {
            Ok(_) => {
                log::info!(
                    "Migrated legacy group data '{}' to '{}'",
                    legacy.display(),
                    path.display()
                );
                path
            }
            Err(err) => {
                log::warn!(
                    "Failed to migrate legacy group data '{}' to '{}': {}",
                    legacy.display(),
                    path.display(),
                    err
                );
                legacy
            }
        }
    }
'''
config = replace_once(config, old_group_path, new_group_path, "Group paths")
# The first Self::readable_path replacement above was Ab. Replace the remaining Group load path.
config = replace_once(
    config,
    '        if let Ok(mut file) = std::fs::File::open(Self::path()) {\n',
    '        if let Ok(mut file) = std::fs::File::open(Self::readable_path()) {\n',
    "Group::load path",
)

old_peer_test = '''    fn test_peer_files_use_explicit_app_names() {
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
new_peer_test = old_peer_test + '''
    #[test]
    fn test_auxiliary_data_paths_use_explicit_app_names() {
        let funtidesk_ab = Ab::path_for_app(FUNTIDESK_APP_NAME);
        let legacy_ab = Ab::path_for_app(LEGACY_APP_NAME);
        let funtidesk_group = Group::path_for_app(FUNTIDESK_APP_NAME);
        let legacy_group = Group::path_for_app(LEGACY_APP_NAME);
        assert_eq!(
            funtidesk_ab.file_name().and_then(|name| name.to_str()),
            Some("FuntiDesk_ab")
        );
        assert_eq!(
            funtidesk_group.file_name().and_then(|name| name.to_str()),
            Some("FuntiDesk_group")
        );
        assert_ne!(funtidesk_ab, legacy_ab);
        assert_ne!(funtidesk_group, legacy_group);
    }
'''
config = replace_once(config, old_peer_test, new_peer_test, "auxiliary path tests")
CONFIG.write_text(config, encoding="utf-8")

common = COMMON.read_text(encoding="utf-8")
common = replace_once(
    common,
    '        self, keys, use_ws, Config, LocalConfig, CONNECT_TIMEOUT, READ_TIMEOUT, RENDEZVOUS_PORT,\n',
    '        self, keys, use_ws, Config, LocalConfig, CONNECT_TIMEOUT, FUNTIDESK_APP_NAME, READ_TIMEOUT,\n        RENDEZVOUS_PORT,\n',
    "FUNTIDESK_APP_NAME import",
)
common = replace_once(
    common,
    '    hbb_common::config::APP_NAME.read().unwrap().eq("RustDesk")\n',
    '    hbb_common::config::APP_NAME\n        .read()\n        .unwrap()\n        .eq(FUNTIDESK_APP_NAME)\n',
    "is_rustdesk semantics",
)
common = replace_once(
    common,
    '    get_app_name() != "RustDesk"\n',
    '    get_app_name() != FUNTIDESK_APP_NAME\n',
    "is_custom_client semantics",
)
COMMON.write_text(common, encoding="utf-8")

print("FUNTIDESK_PHASE2_AUX_PATCH_OK=true")
