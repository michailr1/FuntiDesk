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
const PORTABLE_NAME: &str = "FuntiDesk-portable.exe";
pub const FINISH_ARG: &str = "--funti-finish-update";
/// Set by FuntiDesk-portable.exe for the copy it unpacked: its own path.
const PORTABLE_ENV: &str = "FUNTIDESK_PORTABLE_EXE";
/// Understood by FuntiDesk-portable.exe: wait for this process before
/// unpacking over its files.
const WAIT_ARG: &str = "--funti-wait-pid";

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

/// Where FuntiDesk-portable.exe unpacks itself (libs/portable).
fn portable_unpack_dir() -> Option<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA")?;
    Some(PathBuf::from(local).join("FuntiDesk").join("portable"))
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

/// What is updated (owner's decision 2026-10-12: every copy, in place).
enum Copy {
    /// A folder with FuntiDesk.exe and its files (install.ps1 or an
    /// unpacked archive): replaced as a whole by `finish()`.
    Folder(PathBuf),
    /// FuntiDesk-portable.exe, which unpacks itself on every start: the
    /// file itself is replaced.
    Portable(PathBuf),
    /// Installed with the service (Program Files): the service updates it,
    /// see `start_service()`.
    Service,
}

fn this_copy() -> Result<Copy, &'static str> {
    // Installed mode: only the service (SYSTEM) may write Program Files.
    if crate::platform::is_installed() {
        return Ok(Copy::Service);
    }
    let Ok(cur) = current_dir() else {
        return Err("funti-update-unsupported-copy");
    };
    let unpacked = portable_unpack_dir().map_or(false, |d| same_path(&d, &cur));
    if unpacked {
        // Replacing the unpacked files would be undone by the next start of
        // the old FuntiDesk-portable.exe. Older ones do not say where they are.
        return match std::env::var_os(PORTABLE_ENV).map(PathBuf::from) {
            Some(exe) if exe.is_file() => Ok(Copy::Portable(exe)),
            _ => Err("funti-update-unsupported-portable-old"),
        };
    }
    if !writable_next_to(&cur) {
        return Err("funti-update-unsupported-copy");
    }
    Ok(Copy::Folder(cur))
}

/// The update works next to the copy (`.update`, `.old`).
fn writable_next_to(dir: &Path) -> bool {
    let probe = sibling(dir, ".update-probe");
    let ok = std::fs::create_dir(&probe).is_ok();
    std::fs::remove_dir(&probe).ok();
    ok
}

pub fn unsupported_reason() -> Option<&'static str> {
    this_copy().err()
}

/// The service installs the update and closes this window itself.
pub fn updated_by_service() -> bool {
    matches!(this_copy(), Ok(Copy::Service))
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
    let copy = match this_copy() {
        Ok(copy) => copy,
        Err(reason) => bail!("{reason}"),
    };
    if matches!(copy, Copy::Service) {
        return request_service_update();
    }
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
    let install = match copy {
        Copy::Folder(dir) => dir,
        Copy::Service => unreachable!("handled above"),
        Copy::Portable(exe) => {
            let data = download(&client, PORTABLE_NAME)?;
            verify(&sums, PORTABLE_NAME, &data)?;
            replace_portable(&exe, &data)?;
            log::info!("FuntiDesk {version} portable ready, handing over to it");
            return Ok(version);
        }
    };
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
            .current_dir(&work)
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

/// Puts the new FuntiDesk-portable.exe in place of `exe` and starts it; it
/// waits for this process before unpacking. The old file stays as `.old`
/// until the next start.
fn replace_portable(exe: &Path, data: &[u8]) -> ResultType<()> {
    let new = exe.with_extension("exe.new");
    let old = exe.with_extension("exe.old");
    std::fs::write(&new, data)?;
    std::fs::remove_file(&old).ok();
    if let Err(e) = std::fs::rename(exe, &old) {
        std::fs::remove_file(&new).ok();
        bail!("{} is busy: {e}", exe.display());
    }
    if let Err(e) = std::fs::rename(&new, exe) {
        std::fs::rename(&old, exe).ok();
        bail!("could not put the new {PORTABLE_NAME} in place: {e}");
    }
    let started = std::process::Command::new(exe)
        .current_dir(exe.parent().unwrap_or(Path::new(".")))
        .arg(WAIT_ARG)
        .arg(std::process::id().to_string())
        .spawn();
    if let Err(e) = started {
        std::fs::remove_file(exe).ok();
        std::fs::rename(&old, exe).ok();
        bail!("could not start the new {PORTABLE_NAME}: {e}");
    }
    Ok(())
}

/// Window side of the installed mode: asks the service to update.
fn request_service_update() -> ResultType<String> {
    match crate::ipc::funti_update_service_blocking() {
        Ok(answer) => match answer.strip_prefix("ok:") {
            Some(version) => Ok(version.to_owned()),
            None => bail!("{}", answer.strip_prefix("err:").unwrap_or(&answer)),
        },
        Err(e) => {
            log::warn!("funti update: service not reachable: {e}");
            bail!("funti-update-service-unreachable")
        }
    }
}

/// Service side of the installed mode (ADR-007, stage 2), run by the
/// `--server` process, which is SYSTEM in installed mode. Downloads and
/// checks the latest release like `start()`, unpacks it to
/// `<install dir>.update\files` (Program Files: users cannot write there,
/// so nothing can be swapped before it runs) and starts the new
/// `FuntiDesk.exe --update` from there with SYSTEM rights in this session.
/// `--update` (upstream `update_me`) stops the service and the windows,
/// copies the files over the installed ones, updates the registry and
/// starts the service again. Any error leaves the installation untouched.
pub fn start_service() -> ResultType<String> {
    use std::sync::atomic::{AtomicBool, Ordering};
    static BUSY: AtomicBool = AtomicBool::new(false);
    if !crate::platform::is_installed() || !crate::platform::is_root() {
        bail!("funti-update-unsupported-service");
    }
    if BUSY.swap(true, Ordering::SeqCst) {
        bail!("an update is already running");
    }
    let res = start_service_();
    BUSY.store(false, Ordering::SeqCst);
    res
}

fn start_service_() -> ResultType<String> {
    let install = PathBuf::from(crate::platform::get_install_info().1);
    if !install.join(EXE_NAME).is_file() {
        bail!("no FuntiDesk in {}", install.display());
    }
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
    remove_staging(&work)?;
    let files = work.join("files");
    std::fs::create_dir_all(&files)?;
    let staged = (|| {
        unpack(&zip, &files)?;
        let exe = files.join(EXE_NAME);
        if !exe.is_file() {
            bail!("{EXE_NAME} is missing from the archive");
        }
        let Some(session) = crate::platform::get_current_process_session_id() else {
            bail!("no session for the update");
        };
        let handle = crate::platform::launch_privileged_process(
            session,
            &format!("\"{}\" --update", exe.display()),
        )?;
        if handle.is_null() {
            bail!("the new FuntiDesk did not start");
        }
        Ok(())
    })();
    if let Err(e) = staged {
        remove_staging(&work).ok();
        return Err(e);
    }
    log::info!("FuntiDesk {version} staged for the service, handing over to --update");
    Ok(version)
}

/// Removes a staging folder; refuses links (a link would redirect a SYSTEM
/// delete or write elsewhere).
fn remove_staging(work: &Path) -> ResultType<()> {
    let Ok(meta) = std::fs::symlink_metadata(work) else {
        return Ok(());
    };
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
        if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 || meta.file_type().is_symlink() {
            bail!("{} is a link", work.display());
        }
    }
    std::fs::remove_dir_all(work)?;
    Ok(())
}

/// Service side: removes what an update left next to the installation.
pub fn cleanup_service() {
    if !crate::platform::is_installed() || !crate::platform::is_root() {
        return;
    }
    std::thread::spawn(|| {
        // `--update` may still be copying from the staging folder.
        std::thread::sleep(Duration::from_secs(60));
        let install = PathBuf::from(crate::platform::get_install_info().1);
        let work = sibling(&install, ".update");
        if work.join("files").exists() {
            if let Err(e) = remove_staging(&work) {
                log::warn!("failed to remove {}: {e}", work.display());
            }
        }
    });
}

/// Peer info of a session (ADR-007, stage 3): the controlling side offers
/// the update when this build is older than the latest release.
pub fn add_peer_info(additions: &mut serde_json::Map<String, serde_json::Value>) {
    additions.insert("funti_build".into(), crate::FUNTI_BUILD.into());
    additions.insert("funti_updatable".into(), this_copy().is_ok().into());
}

/// Remote update (ADR-007, stage 3), run by the `--server` process that
/// serves the session: the service installs it in installed mode, otherwise
/// the same steps as "Update" in this copy, then this process exits and the
/// new copy starts. `reply` gets "ok:<version>" or "err:<reason>".
pub fn start_remote(reply: impl FnOnce(String) + Send + 'static) {
    use std::sync::atomic::{AtomicBool, Ordering};
    static BUSY: AtomicBool = AtomicBool::new(false);
    if BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let service = crate::platform::is_installed();
        let res = if service { start_service() } else { start() };
        match res {
            Ok(version) => {
                log::info!("remote update to {version} started");
                reply(format!("ok:{version}"));
                if !service {
                    // Let the answer leave before the session drops.
                    std::thread::sleep(Duration::from_millis(500));
                    exit_for_update();
                }
            }
            Err(e) => {
                log::warn!("remote update failed: {e}");
                BUSY.store(false, Ordering::SeqCst);
                reply(format!("err:{e}"));
            }
        }
    });
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
    // Its own folder as the working directory: the staging folder we run in
    // would stay busy and `cleanup()` could not remove it.
    if let Err(e) = std::process::Command::new(dir.join(EXE_NAME))
        .current_dir(dir)
        .spawn()
    {
        log::error!("failed to start {}: {e}", dir.display());
    }
}

/// `--funti-finish-update <pid> <install dir>`, run from the staged copy.
pub fn finish(args: &[String]) {
    if let Err(e) = finish_(args) {
        log::error!("update not installed: {e}");
        // Whatever failed, FuntiDesk must be running again: the old copy
        // (or the restored one) is still in place.
        if let Some(install) = args.get(2).map(PathBuf::from) {
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
    let install = PathBuf::from(target);
    let work = sibling(&install, ".update");
    // Only a FuntiDesk folder, only from the staging folder next to it.
    if !install.join(EXE_NAME).is_file() || !same_path(&current_dir()?, &work.join("files")) {
        bail!("refusing to update {}", install.display());
    }
    // The old copy may have started us with its working directory, the
    // install dir (a Start menu shortcut sets it): a working directory
    // inside it keeps Windows from renaming it (2026-10-12).
    std::env::set_current_dir(&work)?;
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
    let Ok(install) = current_dir() else {
        return;
    };
    let portable_old = std::env::var_os(PORTABLE_ENV)
        .map(|exe| PathBuf::from(exe).with_extension("exe.old"));
    std::thread::spawn(move || {
        // The staged copy may still be exiting.
        std::thread::sleep(Duration::from_secs(10));
        if let Some(old) = portable_old.filter(|p| p.is_file()) {
            if let Err(e) = std::fs::remove_file(&old) {
                log::warn!("failed to remove {}: {e}", old.display());
            }
        }
        // Only what an update left: a FuntiDesk folder and its staging.
        for (suffix, marker) in [(".old", EXE_NAME), (".update", "files")] {
            let dir = sibling(&install, suffix);
            if dir.join(marker).exists() {
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
