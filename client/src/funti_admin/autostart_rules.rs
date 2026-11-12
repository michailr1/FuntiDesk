//! FUNTIDESK (ADR-023, stage 2b): programs that start with Windows — the
//! requests, where they come from and the "approved" mark that Task
//! Manager uses to switch one off without deleting it. Only std and
//! serde_json here, so this file is also built and tested on its own.

use serde_json::{json, Value};

const TEXT_MAX: usize = 260;

/// Where an entry lives. Its "approved" mark lives under
/// `...\Explorer\StartupApproved\<approved_key>` of the same hive.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Source {
    /// HKLM Run: every user.
    Machine,
    /// HKLM WOW6432Node Run: every user, 32-bit programs.
    Machine32,
    /// The Run key of the signed-in user.
    User,
    /// The "Startup" folder of every user.
    CommonFolder,
    /// The "Startup" folder of the signed-in user.
    UserFolder,
}

pub const SOURCES: [Source; 5] =
    [Source::Machine, Source::Machine32, Source::User, Source::CommonFolder, Source::UserFolder];

impl Source {
    pub fn id(self) -> &'static str {
        match self {
            Source::Machine => "machine",
            Source::Machine32 => "machine32",
            Source::User => "user",
            Source::CommonFolder => "common-folder",
            Source::UserFolder => "user-folder",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        SOURCES.into_iter().find(|s| s.id() == id)
    }

    pub fn approved_key(self) -> &'static str {
        match self {
            Source::Machine | Source::User => "Run",
            Source::Machine32 => "Run32",
            Source::CommonFolder | Source::UserFolder => "StartupFolder",
        }
    }

    /// Entries of the signed-in user (in HKEY_USERS\<SID>).
    pub fn per_user(self) -> bool {
        matches!(self, Source::User | Source::UserFolder)
    }
}

pub enum Request {
    List,
    Set(Source, String, bool),
    Bad,
}

pub fn parse_request(v: &Value) -> Request {
    match v["op"].as_str() {
        Some("autostart") => Request::List,
        Some("autostart_set") => {
            let source = v["source"].as_str().and_then(Source::from_id);
            let name = v["name"].as_str().filter(|n| name_ok(n));
            match (source, name, v["enabled"].as_bool()) {
                (Some(s), Some(n), Some(e)) => Request::Set(s, n.to_owned(), e),
                _ => Request::Bad,
            }
        }
        _ => Request::Bad,
    }
}

/// A value name or a file name in the Startup folder: no path parts.
pub fn name_ok(name: &str) -> bool {
    !name.trim().is_empty()
        && name.chars().count() <= TEXT_MAX
        && !name.chars().any(|c| c.is_control() || c == '\\' || c == '/')
        && name != "."
        && name != ".."
}

/// The "approved" mark: no mark, or an even first byte, means on.
pub fn enabled(mark: Option<&[u8]>) -> bool {
    mark.and_then(|m| m.first()).map_or(true, |b| b & 1 == 0)
}

/// The mark Task Manager writes: 0x02 and zeros to switch on, 0x03 and the
/// time (FILETIME) to switch off.
pub fn mark(enabled: bool, filetime: u64) -> Vec<u8> {
    let mut m = vec![0u8; 12];
    if enabled {
        m[0] = 0x02;
    } else {
        m[0] = 0x03;
        m[4..12].copy_from_slice(&filetime.to_le_bytes());
    }
    m
}

/// "C:\Users\Мама" and "%SystemDrive%\Users\Мама" are the same profile.
pub fn same_profile(registry_path: &str, home: &str, system_drive: &str) -> bool {
    let expanded = registry_path.replace("%SystemDrive%", system_drive).replace("%SYSTEMDRIVE%", system_drive);
    let norm = |p: &str| p.trim_end_matches('\\').to_lowercase();
    !home.is_empty() && norm(&expanded) == norm(home)
}

pub struct Entry {
    pub source: Source,
    pub name: String,
    pub command: String,
    pub enabled: bool,
}

fn text(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(TEXT_MAX).collect()
}

/// FuntiDesk's own entry stays: it keeps the computer reachable.
pub fn protected(name: &str, own: &str) -> bool {
    let plain = |n: &str| {
        let n = n.trim().to_lowercase();
        n.strip_suffix(".lnk").map(str::to_owned).unwrap_or(n)
    };
    plain(name) == plain(own)
}

/// Switched-on entries first, then by name.
pub fn list_json(mut list: Vec<Entry>, own: &str) -> Value {
    list.sort_by(|a, b| {
        b.enabled.cmp(&a.enabled).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    json!({
        "op": "autostart",
        "entries": list.iter().map(|e| json!({
            "source": e.source.id(),
            "name": text(&e.name),
            "command": text(&e.command),
            "enabled": e.enabled,
            "protected": protected(&e.name, own),
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(s: &str) -> Request {
        parse_request(&serde_json::from_str(s).unwrap())
    }

    #[test]
    fn requests() {
        assert!(matches!(req("{\"op\":\"autostart\"}"), Request::List));
        assert!(matches!(
            req("{\"op\":\"autostart_set\",\"source\":\"user\",\"name\":\"Steam\",\"enabled\":false}"),
            Request::Set(Source::User, n, false) if n == "Steam"
        ));
        assert!(matches!(
            req("{\"op\":\"autostart_set\",\"source\":\"common-folder\",\"name\":\"Тест.lnk\",\"enabled\":true}"),
            Request::Set(Source::CommonFolder, _, true)
        ));
        for bad in [
            "{\"op\":\"autostart_set\",\"source\":\"user\",\"name\":\"Steam\"}",
            "{\"op\":\"autostart_set\",\"source\":\"hkcr\",\"name\":\"Steam\",\"enabled\":true}",
            "{\"op\":\"autostart_set\",\"source\":\"user\",\"name\":\"..\\\\x\",\"enabled\":true}",
            "{\"op\":\"autostart_set\",\"source\":\"user-folder\",\"name\":\"..\",\"enabled\":true}",
            "{\"op\":\"autostart_set\",\"source\":\"user\",\"name\":\" \",\"enabled\":true}",
            "{\"op\":\"autostart_set\",\"source\":\"user\",\"name\":\"a\\nb\",\"enabled\":true}",
            "{\"op\":\"remove\"}",
        ] {
            assert!(matches!(req(bad), Request::Bad), "{bad}");
        }
        for s in SOURCES {
            assert_eq!(Source::from_id(s.id()), Some(s));
        }
        assert!(Source::User.per_user() && Source::UserFolder.per_user() && !Source::Machine.per_user());
        assert_eq!(Source::Machine32.approved_key(), "Run32");
        assert_eq!(Source::UserFolder.approved_key(), "StartupFolder");
    }

    #[test]
    fn the_approved_mark() {
        assert!(enabled(None));
        assert!(enabled(Some(&[])));
        assert!(enabled(Some(&[0x02, 0, 0])));
        assert!(enabled(Some(&[0x06])));
        assert!(!enabled(Some(&[0x03, 1, 2])));
        assert!(!enabled(Some(&[0x07])));
        assert_eq!(mark(true, 99), vec![2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let off = mark(false, 0x0102030405060708);
        assert_eq!(off.len(), 12);
        assert_eq!(off[0], 3);
        assert_eq!(&off[4..], &[8, 7, 6, 5, 4, 3, 2, 1]);
        assert!(!enabled(Some(&off)));
        assert!(enabled(Some(&mark(true, 0))));
    }

    #[test]
    fn profiles() {
        assert!(same_profile("%SystemDrive%\\Users\\Мама", "C:\\Users\\Мама", "C:"));
        assert!(same_profile("C:\\Users\\mama\\", "c:\\users\\MAMA", "C:"));
        assert!(!same_profile("C:\\Users\\Папа", "C:\\Users\\Мама", "C:"));
        assert!(!same_profile("C:\\Users\\Мама", "", "C:"));
    }

    #[test]
    fn the_list() {
        let list = vec![
            Entry { source: Source::User, name: "Zoom".into(), command: "zoom.exe".into(), enabled: false },
            Entry { source: Source::Machine, name: "FuntiDesk".into(), command: "x".into(), enabled: true },
            Entry { source: Source::UserFolder, name: "notes.lnk".into(), command: "C:\\a\nb".into(), enabled: true },
        ];
        let v = list_json(list, "FuntiDesk");
        let rows = v["entries"].as_array().unwrap();
        let names: Vec<_> = rows.iter().map(|r| r["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["FuntiDesk", "notes.lnk", "Zoom"]);
        assert_eq!(rows[0]["protected"], true);
        assert_eq!(rows[1]["source"], "user-folder");
        assert_eq!(rows[1]["command"], "C:\\ab");
        assert_eq!(rows[2]["enabled"], false);
        assert!(protected("funtidesk.lnk", "FuntiDesk"));
        assert!(!protected("Steam", "FuntiDesk"));
    }
}
