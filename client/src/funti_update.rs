// FUNTIDESK (ADR-007): "Check for updates" / "Update" for the Windows client
// installed by install.ps1 into %LOCALAPPDATA%\Programs\FuntiDesk.
//
// Trust is the same as install.ps1: only the latest FuntiDesk release on
// GitHub over HTTPS, SHA-256 from SHA256SUMS.txt of the same release. The
// address is fixed here; there is no mirror and no fallback. Any error keeps
// the installed copy untouched.
//
// Order of work:
// 1. `check()` reads funtidesk-version.txt (`1.4.9-ft.N`) and compares N with
//    our FUNTI_BUILD.
// 2. `start()` downloads the release, checks the hashes, unpacks it to
//    `Programs\FuntiDesk.update\files`, starts the new FuntiDesk.exe from
//    there with `--funti-finish-update <pid> <install dir>` and exits.
// 3. `finish()` (in the new exe) waits for the old process, renames the
//    install dir to `FuntiDesk.old`, copies the new files in, starts the
//    installed exe. On failure it puts the old dir back and starts it.
// 4. `cleanup()` on the next normal start removes `.old` and `.update`.
//
// `--funti-finish-update <pid> <dir>` is called by the OLD version on the NEW
// one: every later version must keep accepting it.

use hbb_common::{bail, log, ResultType};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

const RELEASE_BASE: &str = "https://github.com/michailr1/FuntiDesk/releases/latest/download";
const ZIP_NAME: &str = "FuntiDesk-windows-x64.zip";
const SUMS_NAME: &str = "SHA256SUMS.txt";
const VERSION_NAME: &str = "funtidesk-version.txt";
const WHATS_NEW_NAME: &str = "funtidesk-whats-new.txt";
const WHATS_NEW_MAX: usize = 16 * 1024;
const EXE_NAME: &str = "FuntiDesk.exe";
pub const FINISH_ARG: &str = "--funti-finish-update";

pub struct Latest {
    pub version: String,
    pub build: u32,
}

/// `1.4.9-ft.N` -> N. Anything else is rejected.
fn parse_build(version: &str) -> Option<u32> {
    let (base, n) = version.trim().split_once("-ft.")?;
    if base.is_empty() || !base.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return None;
    }
    n.parse().ok().filter(|n| *n > 0)
}

/// Newer than this build. A build without a number (0) takes any release,
/// but only on the explicit button (ADR-007).
pub fn is_newer(build: u32) -> bool {
    crate::FUNTI_BUILD == 0 || build > crate::FUNTI_BUILD
}

fn http() -> ResultType<reqwest::blocking::Client> {
    // GitHub answers releases/latest/download with redirects to its own
    // storage. Follow them only within GitHub, only over HTTPS.
    let policy = reqwest::redirect::Policy::custom(|attempt| {
        let url = attempt.url();
        let host = url.host_str().unwrap_or_default().to_lowercase();
        let github = host == "github.com"
            || host.ends_with(".github.com")
            || host.ends_with(".githubusercontent.com");
        if attempt.previous().len() > 5 {
            attempt.error("too many redirects")
        } else if url.scheme() != "https" || !github {
            attempt.error(format!("redirect to an untrusted address: {host}"))
        } else {
            attempt.follow()
        }
    });
    Ok(reqwest::blocking::Client::builder()
        .use_rustls_tls()
        .https_only(true)
        .no_proxy()
        .redirect(policy)
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(600))
        .user_agent("FuntiDesk-update")
        .build()?)
}

fn download(client: &reqwest::blocking::Client, name: &str) -> ResultType<Vec<u8>> {
    let resp = client.get(format!("{RELEASE_BASE}/{name}")).send()?;
    if !resp.status().is_success() {
        bail!("{name}: HTTP {}", resp.status());
    }
    Ok(resp.bytes()?.to_vec())
}

pub fn check() -> ResultType<Latest> {
    let bytes = download(&http()?, VERSION_NAME)?;
    let version = String::from_utf8_lossy(&bytes).trim().to_owned();
    let Some(build) = parse_build(&version) else {
        bail!("unexpected version in the release: {version:?}");
    };
    Ok(Latest { version, build })
}

/// "What's new" of the latest release, for the notice on the main screen.
/// Checked against SHA256SUMS.txt like the other files of the release.
pub fn whats_new() -> ResultType<String> {
    let client = http()?;
    let text = download(&client, WHATS_NEW_NAME)?;
    let sums = String::from_utf8(download(&client, SUMS_NAME)?)?;
    verify(&sums, WHATS_NEW_NAME, &text)?;
    if text.len() > WHATS_NEW_MAX {
        bail!("{WHATS_NEW_NAME} is too large");
    }
    Ok(String::from_utf8(text)?.trim().to_owned())
}

fn expected_hash<'a>(sums: &'a str, name: &str) -> Option<&'a str> {
    sums.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let file = parts.next()?;
        (parts.next().is_none() && file.trim_start_matches('*') == name).then_some(hash)
    })
}

fn verify(sums: &str, name: &str, data: &[u8]) -> ResultType<()> {
    let Some(expected) = expected_hash(sums, name) else {
        bail!("{name} is missing from {SUMS_NAME}");
    };
    let actual = hex::encode(Sha256::digest(data));
    if !actual.eq_ignore_ascii_case(expected) {
        bail!("checksum mismatch for {name}");
    }
    Ok(())
}

/// %LOCALAPPDATA%\Programs\FuntiDesk, where install.ps1 puts FuntiDesk.
fn install_dir() -> ResultType<PathBuf> {
    let Some(local) = std::env::var_os("LOCALAPPDATA") else {
        bail!("LOCALAPPDATA is not set");
    };
    Ok(PathBuf::from(local).join("Programs").join("FuntiDesk"))
}

fn sibling(dir: &Path, suffix: &str) -> PathBuf {
    let mut name = dir.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    dir.with_file_name(name)
}

fn same_path(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

fn current_dir() -> ResultType<PathBuf> {
    let exe = std::env::current_exe()?;
    let Some(dir) = exe.parent() else {
        bail!("no directory for {}", exe.display());
    };
    Ok(dir.to_path_buf())
}

/// Only the copy installed by install.ps1 updates itself. The service
/// (installed mode) and other copies are not supported yet: fail closed.
pub fn unsupported_reason() -> Option<&'static str> {
    if crate::platform::is_installed() {
        return Some("funti-update-unsupported-service");
    }
    match (install_dir(), current_dir()) {
        (Ok(install), Ok(cur)) if same_path(&install, &cur) => None,
        _ => Some("funti-update-unsupported-copy"),
    }
}

fn unpack(zip: &[u8], to: &Path) -> ResultType<()> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(zip))?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let Some(rel) = entry.enclosed_name().map(|p| p.to_path_buf()) else {
            bail!("unsafe path in the archive: {}", entry.name());
        };
        let path = to.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&path)?;
            continue;
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::fs::File::create(&path)?;
        std::io::copy(&mut entry, &mut file)?;
    }
    Ok(())
}

/// Download, check and unpack the latest release, start the new exe to swap
/// the files. On success the caller exits the process.
pub fn start() -> ResultType<String> {
    if let Some(reason) = unsupported_reason() {
        bail!("{reason}");
    }
    let install = install_dir()?;
    let client = http()?;
    let version_bytes = download(&client, VERSION_NAME)?;
    let sums = String::from_utf8(download(&client, SUMS_NAME)?)?;
    verify(&sums, VERSION_NAME, &version_bytes)?;
    let version = String::from_utf8_lossy(&version_bytes).trim().to_owned();
    match parse_build(&version) {
        Some(build) if is_newer(build) => {}
        Some(_) => bail!("the release {version} is not newer than this copy"),
        None => bail!("unexpected version in the release: {version:?}"),
    }
    let zip = download(&client, ZIP_NAME)?;
    verify(&sums, ZIP_NAME, &zip)?;

    let work = sibling(&install, ".update");
    if work.exists() {
        std::fs::remove_dir_all(&work)?;
    }
    let files = work.join("files");
    std::fs::create_dir_all(&files)?;
    let staged = (|| {
        unpack(&zip, &files)?;
        if !files.join(EXE_NAME).is_file() {
            bail!("{EXE_NAME} is missing from the archive");
        }
        std::process::Command::new(files.join(EXE_NAME))
            .arg(FINISH_ARG)
            .arg(std::process::id().to_string())
            .arg(&install)
            .spawn()?;
        Ok(())
    })();
    if let Err(e) = staged {
        std::fs::remove_dir_all(&work).ok();
        return Err(e);
    }
    log::info!("FuntiDesk {version} staged, handing over to the new copy");
    Ok(version)
}

/// Exit after `start()`: close the other FuntiDesk processes of this copy
/// (connection manager, tray), then this one.
pub fn exit_for_update() {
    if let Ok(dir) = current_dir() {
        kill_copies_in(&dir, Some(std::process::id()));
    }
    // A normal exit with the Flutter engine running took more than 30 s
    // (2026-10-11); the new copy is waiting, so leave at once.
    use windows::Win32::System::Threading::{GetCurrentProcess, TerminateProcess};
    unsafe {
        let _ = TerminateProcess(GetCurrentProcess(), 0);
    }
    std::process::exit(0);
}

fn kill_copies_in(dir: &Path, except: Option<u32>) {
    use hbb_common::sysinfo::System;
    let system = System::new_all();
    for (pid, process) in system.processes() {
        if Some(pid.as_u32()) == except || !process.name().eq_ignore_ascii_case(EXE_NAME) {
            continue;
        }
        if process.exe().parent().map_or(false, |p| same_path(p, dir)) {
            process.kill();
        }
    }
}

/// Waits for process `pid` to end; true when it is gone.
fn wait_exit(pid: u32, timeout: Duration) -> bool {
    use windows::Win32::{
        Foundation::{CloseHandle, WAIT_OBJECT_0},
        System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE},
    };
    let Ok(handle) = (unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, pid) }) else {
        return true;
    };
    let res = unsafe { WaitForSingleObject(handle, timeout.as_millis() as u32) };
    unsafe {
        let _ = CloseHandle(handle);
    }
    res == WAIT_OBJECT_0
}

fn terminate(pid: u32) {
    use windows::Win32::{
        Foundation::CloseHandle,
        System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE},
    };
    if let Ok(handle) = unsafe { OpenProcess(PROCESS_TERMINATE, false, pid) } {
        unsafe {
            let _ = TerminateProcess(handle, 1);
            let _ = CloseHandle(handle);
        }
    }
}

fn running_in(dir: &Path) -> bool {
    use hbb_common::sysinfo::System;
    System::new_all().processes().values().any(|p| {
        p.name().eq_ignore_ascii_case(EXE_NAME)
            && p.exe().parent().map_or(false, |p| same_path(p, dir))
    })
}

fn copy_dir(from: &Path, to: &Path) -> ResultType<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn launch(dir: &Path) {
    if let Err(e) = std::process::Command::new(dir.join(EXE_NAME)).spawn() {
        log::error!("failed to start {}: {e}", dir.display());
    }
}

/// `--funti-finish-update <pid> <install dir>`, run from the staged copy.
pub fn finish(args: &[String]) {
    if let Err(e) = finish_(args) {
        log::error!("update not installed: {e}");
        // Whatever failed, FuntiDesk must be running again: the old copy
        // (or the restored one) is still in place.
        if let Ok(install) = install_dir() {
            if install.join(EXE_NAME).is_file() && !running_in(&install) {
                launch(&install);
            }
        }
    }
}

fn finish_(args: &[String]) -> ResultType<()> {
    let (Some(pid), Some(target)) = (args.get(1), args.get(2)) else {
        bail!("bad arguments");
    };
    let pid: u32 = pid.parse()?;
    let install = install_dir()?;
    let target = PathBuf::from(target);
    let work = sibling(&install, ".update");
    // Only the install.ps1 location, only from our own staging folder.
    if !same_path(&target, &install) || !same_path(&current_dir()?, &work.join("files")) {
        bail!("refusing to update {}", target.display());
    }
    if !wait_exit(pid, Duration::from_secs(20)) {
        // It asked for this update itself; a slow exit must not block it.
        log::warn!("the old FuntiDesk ({pid}) is still running, closing it");
        terminate(pid);
        if !wait_exit(pid, Duration::from_secs(10)) {
            bail!("the old FuntiDesk ({pid}) did not exit");
        }
    }
    kill_copies_in(&install, None);

    let old = sibling(&install, ".old");
    if old.exists() {
        std::fs::remove_dir_all(&old)?;
    }
    let mut renamed = false;
    for _ in 0..40 {
        if std::fs::rename(&install, &old).is_ok() {
            renamed = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    if !renamed {
        launch(&install);
        bail!("{} is busy", install.display());
    }
    if let Err(e) = copy_dir(&work.join("files"), &install) {
        std::fs::remove_dir_all(&install).ok();
        if std::fs::rename(&old, &install).is_err() {
            log::error!("could not restore {}", install.display());
        }
        launch(&install);
        bail!("copy failed: {e}");
    }
    log::info!("update installed");
    launch(&install);
    Ok(())
}

/// Leftovers of a previous update, removed on a normal start.
pub fn cleanup() {
    let Ok(install) = install_dir() else {
        return;
    };
    let Ok(cur) = current_dir() else {
        return;
    };
    if !same_path(&install, &cur) {
        return;
    }
    std::thread::spawn(move || {
        // The staged copy may still be exiting.
        std::thread::sleep(Duration::from_secs(10));
        for suffix in [".old", ".update"] {
            let dir = sibling(&install, suffix);
            if dir.exists() {
                if let Err(e) = std::fs::remove_dir_all(&dir) {
                    log::warn!("failed to remove {}: {e}", dir.display());
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_numbers() {
        assert_eq!(parse_build("1.4.9-ft.12393\n"), Some(12393));
        assert_eq!(parse_build("1.4.9-ft.0"), None);
        assert_eq!(parse_build("1.4.9"), None);
        assert_eq!(parse_build("x-ft.5"), None);
        assert_eq!(parse_build("-ft.5"), None);
    }

    #[test]
    fn sums() {
        let sums = "aa  FuntiDesk-windows-x64.zip\nbb  funtidesk-version.txt\n";
        assert_eq!(expected_hash(sums, ZIP_NAME), Some("aa"));
        assert_eq!(expected_hash(sums, VERSION_NAME), Some("bb"));
        assert_eq!(expected_hash(sums, "other"), None);
        let data = b"1.4.9-ft.7\n";
        let line = format!("{}  {VERSION_NAME}", hex::encode(Sha256::digest(data)));
        assert!(verify(&line, VERSION_NAME, data).is_ok());
        assert!(verify(&line, VERSION_NAME, b"1.4.9-ft.8\n").is_err());
    }
}
