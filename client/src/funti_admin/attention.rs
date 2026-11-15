//! FUNTIDESK (ADR-024, stage 4): the Windows facts behind "needs attention":
//! a pending restart from the registry; antivirus, Defender and the last
//! Windows Update installation from one PowerShell run.

use super::attention_rules::{self as rules, Facts};
use std::os::windows::process::CommandExt;
use std::process::Command;
use winreg::{enums::*, RegKey};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Security Center (absent on Windows Server), Defender, and the last
/// successful Windows Update installation as Unix time. Each part may fail
/// on its own; the rest is still answered.
const SCRIPT: &str = r#"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$o = @{}
try { $o.av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
  ForEach-Object { @{ name = $_.displayName; state = [int64]$_.productState } }) } catch {}
try { $s = Get-MpComputerStatus -ErrorAction Stop
  $o.defender = @{ av = [bool]$s.AntivirusEnabled; rt = [bool]$s.RealTimeProtectionEnabled; age = [int64]$s.AntivirusSignatureAge } } catch {}
try { $d = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
  if ($d) { $o.update = [int64]([DateTimeOffset]$d.ToUniversalTime()).ToUnixTimeSeconds() } } catch {}
$o | ConvertTo-Json -Compress -Depth 4
"#;

fn restart_pending() -> bool {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let key = |path: &str| hklm.open_subkey_with_flags(path, KEY_READ).is_ok();
    key("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending")
        || key("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired")
        || hklm
            .open_subkey_with_flags("SYSTEM\\CurrentControlSet\\Control\\Session Manager", KEY_READ)
            .and_then(|k| k.get_raw_value("PendingFileRenameOperations"))
            .map_or(false, |v| v.bytes.len() > 4)
}

pub fn facts(facts: &mut Facts) {
    facts.restart_pending = restart_pending();
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", SCRIPT])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    match output {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            let start = text.find('{').unwrap_or(0);
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(text[start..].trim()) {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |d| d.as_secs() as i64);
                rules::parse_powershell(&v, now, facts);
            }
        }
        Err(e) => hbb_common::log::info!("FuntiDesk attention: {}", e),
    }
}
