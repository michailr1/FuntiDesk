//! FUNTIDESK (ADR-024, stage 5): installed programs, as "Apps & features"
//! lists them, and how one can be removed without anyone at that computer:
//! by Windows Installer, or by the program's own quiet uninstaller. Only
//! std and serde_json here, so this file is also built and tested on its own.

use serde_json::{json, Value};

/// Where an entry of the Uninstall key lives.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Hive {
    Machine,
    Machine32,
    User,
}

pub const HIVES: [Hive; 3] = [Hive::Machine, Hive::Machine32, Hive::User];

impl Hive {
    pub fn id(self) -> &'static str {
        match self {
            Hive::Machine => "machine",
            Hive::Machine32 => "machine32",
            Hive::User => "user",
        }
    }
}

/// The values of one Uninstall subkey that matter.
#[derive(Debug, Default, Clone)]
pub struct Raw {
    pub key: String,
    pub name: String,
    pub version: String,
    pub publisher: String,
    pub install_date: String,
    pub size_kb: u64,
    pub uninstall: String,
    pub quiet_uninstall: String,
    pub system_component: bool,
    pub parent: bool,
    pub release_type: String,
    pub windows_installer: bool,
}

#[derive(Debug, PartialEq)]
pub enum Method {
    /// `msiexec /x {GUID} /qn /norestart`.
    Msi(String),
    /// The program's own quiet command.
    Quiet(String),
    /// It would show a window nobody sees: remove in a screen session.
    Manual,
}

/// Shown in the list: has a name, is not a part of Windows or an update.
pub fn listed(r: &Raw) -> bool {
    !r.name.trim().is_empty()
        && !r.system_component
        && !r.parent
        && !matches!(r.release_type.as_str(), "Update" | "Hotfix" | "Security Update")
}

/// "{8A69D345-…}" from an MsiExec command line or the key name.
fn product_code(s: &str) -> Option<String> {
    let start = s.find('{')?;
    let end = start + s[start..].find('}')?;
    let guid = &s[start..=end];
    let ok = guid.len() == 38 && guid[1..37].chars().all(|c| c.is_ascii_hexdigit() || c == '-');
    ok.then(|| guid.to_owned())
}

pub fn method(r: &Raw) -> Method {
    let msi = r.windows_installer || r.uninstall.to_ascii_lowercase().contains("msiexec");
    if msi {
        if let Some(code) = product_code(&r.uninstall).or_else(|| product_code(&r.key)) {
            return Method::Msi(code);
        }
    }
    if !r.quiet_uninstall.trim().is_empty() {
        return Method::Quiet(r.quiet_uninstall.trim().to_owned());
    }
    Method::Manual
}

/// FuntiDesk removes itself only from its own settings.
pub fn protected(r: &Raw) -> bool {
    r.name.to_ascii_lowercase().contains("funtidesk")
}

pub fn list_json(entries: &[(Hive, Raw)]) -> Value {
    let mut list: Vec<Value> = entries
        .iter()
        .filter(|(_, r)| listed(r))
        .map(|(hive, r)| {
            json!({
                "id": format!("{}:{}", hive.id(), r.key),
                "name": r.name.trim(),
                "version": r.version,
                "publisher": r.publisher,
                "date": r.install_date,
                "size": r.size_kb * 1024,
                "removable": !protected(r) && method(r) != Method::Manual,
                "protected": protected(r),
            })
        })
        .collect();
    list.sort_by_key(|v| v["name"].as_str().unwrap_or("").to_lowercase());
    list.dedup_by(|a, b| a["name"] == b["name"] && a["version"] == b["version"]);
    json!({"op": "programs", "programs": list})
}

/// "machine:{GUID}" → (hive, subkey); None for anything else.
pub fn parse_id(id: &str) -> Option<(Hive, String)> {
    let (hive, key) = id.split_once(':')?;
    let hive = HIVES.into_iter().find(|h| h.id() == hive)?;
    let ok = !key.is_empty() && key.len() <= 260 && !key.contains('\\') && !key.contains('/');
    ok.then(|| (hive, key.to_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(name: &str, uninstall: &str) -> Raw {
        Raw { key: "k".into(), name: name.into(), uninstall: uninstall.into(), ..Default::default() }
    }

    #[test]
    fn methods() {
        let r = raw("7-Zip", "MsiExec.exe /I{23170F69-40C1-2702-2201-000001000000}");
        assert_eq!(method(&r), Method::Msi("{23170F69-40C1-2702-2201-000001000000}".into()));
        let mut r = raw("App", "\"C:\\App\\unins000.exe\"");
        assert_eq!(method(&r), Method::Manual);
        r.quiet_uninstall = "\"C:\\App\\unins000.exe\" /SILENT".into();
        assert_eq!(method(&r), Method::Quiet("\"C:\\App\\unins000.exe\" /SILENT".into()));
        let mut r = raw("Office", "");
        r.windows_installer = true;
        r.key = "{90160000-008C-0000-1000-0000000FF1CE}".into();
        assert!(matches!(method(&r), Method::Msi(_)));
        assert_eq!(method(&raw("Bad", "msiexec /x {not-a-guid}")), Method::Manual);
    }

    #[test]
    fn listing() {
        let mut update = raw("KB5005463", "x");
        update.release_type = "Update".into();
        let mut part = raw("Part", "x");
        part.system_component = true;
        let mut a = raw("Zeta", "msiexec /x{23170F69-40C1-2702-2201-000001000000}");
        a.size_kb = 2;
        let b = raw("alpha", "x");
        let own = raw("FuntiDesk", "msiexec /x{23170F69-40C1-2702-2201-000001000001}");
        let entries = vec![
            (Hive::Machine, a.clone()),
            (Hive::Machine32, a),
            (Hive::User, b),
            (Hive::Machine, update),
            (Hive::Machine, part),
            (Hive::Machine, raw("  ", "x")),
            (Hive::Machine, own),
        ];
        let v = list_json(&entries);
        let names: Vec<&str> = v["programs"].as_array().unwrap().iter().map(|p| p["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["alpha", "FuntiDesk", "Zeta"]);
        let p = &v["programs"];
        assert_eq!((p[0]["removable"].as_bool(), p[1]["removable"].as_bool(), p[2]["removable"].as_bool()), (Some(false), Some(false), Some(true)));
        assert_eq!(p[1]["protected"], true);
        assert_eq!(p[2]["size"], 2048);
        assert_eq!(p[0]["id"], "user:k");
    }

    #[test]
    fn ids() {
        assert_eq!(parse_id("machine32:{X}"), Some((Hive::Machine32, "{X}".into())));
        assert_eq!(parse_id("user:..\\Run"), None);
        assert_eq!(parse_id("hklm:x"), None);
        assert_eq!(parse_id("machine:"), None);
        assert_eq!(parse_id("nocolon"), None);
    }
}
