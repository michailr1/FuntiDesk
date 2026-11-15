//! FUNTIDESK (ADR-024, stage 5): drives with their health and wear, and the
//! serial number, from one PowerShell run (Windows Storage and CIM).

use super::storage_rules as rules;
use std::os::windows::process::CommandExt;
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

const SCRIPT: &str = r#"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$o = @{}
try { $o.serial = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch {}
try { $o.disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
  $r = $null; try { $r = $_ | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
  @{ name = $_.FriendlyName; media = [int]$_.MediaType; bus = [int]$_.BusType; size = [int64]$_.Size;
     health = [int]$_.HealthStatus; temp = $r.Temperature; wear = $r.Wear; hours = $r.PowerOnHours;
     readErrors = $r.ReadErrorsTotal } }) } catch {}
$o | ConvertTo-Json -Compress -Depth 4
"#;

pub fn hardware() -> String {
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", SCRIPT])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    let value = match output {
        Ok(out) => {
            let text = String::from_utf8_lossy(&out.stdout);
            let start = text.find('{').unwrap_or(0);
            serde_json::from_str::<serde_json::Value>(text[start..].trim()).unwrap_or_default()
        }
        Err(e) => {
            hbb_common::log::info!("FuntiDesk hardware: {}", e);
            serde_json::Value::Null
        }
    };
    let (serial, drives) = rules::parse_powershell(&value);
    rules::answer_json(&serial, &drives).to_string()
}
