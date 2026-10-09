//! FUNTIDESK (ADR-005): incoming call ring in the connection manager window.
//! The tone is our own (res/funti-ring.wav, synthesized), played in a loop
//! with the system PlaySound until the call is answered, declined or gone.

#[cfg(windows)]
mod imp {
    use std::{ffi::c_void, ptr, sync::Mutex};

    static RING: &[u8] = include_bytes!("../res/funti-ring.wav");
    static STATE: Mutex<bool> = Mutex::new(false);

    const SND_ASYNC: u32 = 0x0001;
    const SND_NODEFAULT: u32 = 0x0002;
    const SND_MEMORY: u32 = 0x0004;
    const SND_LOOP: u32 = 0x0008;

    #[link(name = "winmm")]
    extern "system" {
        fn PlaySoundW(sound: *const u16, module: *mut c_void, flags: u32) -> i32;
    }

    pub fn set(on: bool) {
        let mut playing = STATE.lock().unwrap();
        if *playing == on {
            return;
        }
        // SAFETY: RING is 'static, as SND_MEMORY with SND_ASYNC requires.
        unsafe {
            if on {
                PlaySoundW(
                    RING.as_ptr() as *const u16,
                    ptr::null_mut(),
                    SND_MEMORY | SND_ASYNC | SND_LOOP | SND_NODEFAULT,
                );
            } else {
                PlaySoundW(ptr::null(), ptr::null_mut(), 0);
            }
        }
        *playing = on;
    }
}

#[cfg(windows)]
pub use imp::set;

#[cfg(not(windows))]
pub fn set(_on: bool) {}
