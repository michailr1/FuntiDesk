//! FUNTIDESK: paths of the files copied on this computer (Explorer, a file
//! manager), for "Paste" in the file transfer window.

use hbb_common::log;

#[cfg(windows)]
pub fn paths() -> Vec<String> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt, ptr, time::Duration};
    use winapi::um::{
        shellapi::{DragQueryFileW, HDROP},
        winuser::{CloseClipboard, GetClipboardData, OpenClipboard, CF_HDROP},
    };

    let mut paths = Vec::new();
    unsafe {
        // Another program may hold the clipboard for a moment.
        let mut opened = false;
        for _ in 0..5 {
            if OpenClipboard(ptr::null_mut()) != 0 {
                opened = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        if !opened {
            log::warn!("Paste files: the clipboard is busy");
            return paths;
        }
        let drop = GetClipboardData(CF_HDROP) as HDROP;
        if !drop.is_null() {
            let count = DragQueryFileW(drop, u32::MAX, ptr::null_mut(), 0);
            for i in 0..count {
                let len = DragQueryFileW(drop, i, ptr::null_mut(), 0);
                if len == 0 {
                    continue;
                }
                let mut buf = vec![0u16; len as usize + 1];
                let n = DragQueryFileW(drop, i, buf.as_mut_ptr(), buf.len() as u32);
                paths.push(
                    OsString::from_wide(&buf[..n as usize])
                        .to_string_lossy()
                        .into_owned(),
                );
            }
        }
        CloseClipboard();
    }
    paths
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub fn paths() -> Vec<String> {
    use arboard::{ClipboardData, ClipboardFormat};

    match arboard::Clipboard::new().and_then(|mut c| c.get_formats(&[ClipboardFormat::FileUrl])) {
        Ok(data) => data
            .into_iter()
            .find_map(|d| match d {
                ClipboardData::FileUrl(paths) => Some(paths),
                _ => None,
            })
            .unwrap_or_default(),
        Err(e) => {
            log::debug!("Paste files: no files in the clipboard: {e}");
            Vec::new()
        }
    }
}
