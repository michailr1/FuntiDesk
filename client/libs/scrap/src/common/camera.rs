use std::{
    io,
    sync::{Arc, Mutex},
};

#[cfg(any(target_os = "windows", target_os = "linux"))]
use nokhwa::{
    pixel_format::RgbAFormat,
    query,
    utils::{ApiBackend, CameraIndex, FrameFormat, RequestedFormat, RequestedFormatType},
    Camera,
};
#[cfg(any(target_os = "windows", target_os = "linux"))]
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Instant,
};

// FUNTIDESK: a camera that opens but never delivers a frame must not hang the
// video service (found 2026-10-09: "Integrated Camera" of a laptop, call stuck
// on "waiting for image", the service never ended). Frames are read on a
// thread of their own; the service gets an error after this long without one.
#[cfg(any(target_os = "windows", target_os = "linux"))]
const FUNTI_NO_FRAME_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

use hbb_common::message_proto::{DisplayInfo, Resolution};

#[cfg(feature = "vram")]
use crate::AdapterDevice;

use crate::common::{bail, ResultType};
use crate::{Frame, TraitCapturer};
#[cfg(any(target_os = "windows", target_os = "linux"))]
use crate::{PixelBuffer, Pixfmt};

pub const PRIMARY_CAMERA_IDX: usize = 0;
lazy_static::lazy_static! {
    static ref SYNC_CAMERA_DISPLAYS: Arc<Mutex<Vec<DisplayInfo>>> = Arc::new(Mutex::new(Vec::new()));
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
const CAMERA_NOT_SUPPORTED: &str = "This platform doesn't support camera yet";

pub struct Cameras;

// pre-condition
pub fn primary_camera_exists() -> bool {
    Cameras::exists(PRIMARY_CAMERA_IDX)
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
impl Cameras {
    pub fn all_info() -> ResultType<Vec<DisplayInfo>> {
        match query(ApiBackend::Auto) {
            Ok(cameras) => {
                let mut camera_displays = SYNC_CAMERA_DISPLAYS.lock().unwrap();
                camera_displays.clear();
                // FIXME: nokhwa returns duplicate info for one physical camera on linux for now.
                // issue: https://github.com/l1npengtul/nokhwa/issues/171
                // Use only one camera as a temporary hack.
                cfg_if::cfg_if! {
                    if #[cfg(target_os = "linux")] {
                        let Some(info) = cameras.first() else {
                            bail!("No camera found")
                        };
                        // Use index (0) camera as main camera, fallback to the first camera if index (0) is not available.
                        // But maybe we also need to check index (1) or the lowest index camera.
                        //
                        // https://askubuntu.com/questions/234362/how-to-fix-this-problem-where-sometimes-dev-video0-becomes-automatically-dev
                        // https://github.com/rustdesk/rustdesk/pull/12010#issue-3125329069
                        let mut camera_index = info.index().clone();
                        if !matches!(camera_index, CameraIndex::Index(0)) {
                            if cameras.iter().any(|cam| matches!(cam.index(), CameraIndex::Index(0))) {
                                camera_index = CameraIndex::Index(0);
                            }
                        }
                        let camera = Self::create_camera(&camera_index)?;
                        let resolution = camera.resolution();
                        let (width, height) = (resolution.width() as i32, resolution.height() as i32);
                        camera_displays.push(DisplayInfo {
                            x: 0,
                            y: 0,
                            name: info.human_name().clone(),
                            width,
                            height,
                            online: true,
                            cursor_embedded: false,
                            scale:1.0,
                            original_resolution: Some(Resolution {
                                width,
                                height,
                                ..Default::default()
                            }).into(),
                            ..Default::default()
                        });
                    } else {
                        let mut x = 0;
                        for info in &cameras {
                            let camera = Self::create_camera(info.index())?;
                            let resolution = camera.resolution();
                            let (width, height) = (resolution.width() as i32, resolution.height() as i32);
                            camera_displays.push(DisplayInfo {
                                x,
                                y: 0,
                                name: info.human_name().clone(),
                                width,
                                height,
                                online: true,
                                cursor_embedded: false,
                                scale:1.0,
                                original_resolution: Some(Resolution {
                                    width,
                                    height,
                                    ..Default::default()
                                }).into(),
                                ..Default::default()
                            });
                            x += width;
                        }
                    }
                }
                Ok(camera_displays.clone())
            }
            Err(e) => {
                bail!("Query cameras error: {}", e)
            }
        }
    }

    pub fn exists(index: usize) -> bool {
        match query(ApiBackend::Auto) {
            Ok(cameras) => index < cameras.len(),
            _ => return false,
        }
    }

    fn create_camera(index: &CameraIndex) -> ResultType<Camera> {
        let format_type = if cfg!(target_os = "linux") {
            RequestedFormatType::None
        } else {
            RequestedFormatType::AbsoluteHighestResolution
        };
        let result = Camera::new(
            index.clone(),
            RequestedFormat::new::<RgbAFormat>(format_type),
        );
        match result {
            Ok(mut camera) => {
                #[cfg(target_os = "windows")]
                Self::funti_pick_format(&mut camera);
                Ok(camera)
            }
            Err(e) => bail!("create camera{} error:  {}", index, e),
        }
    }

    // FUNTIDESK: "absolute highest resolution" may pick a mode some cameras
    // never stream in. Prefer the largest mode with at least 15 fps in a
    // common format (NV12, MJPEG, YUYV); log what the camera offers.
    #[cfg(target_os = "windows")]
    fn funti_pick_format(camera: &mut Camera) {
        let formats = match camera.compatible_camera_formats() {
            Ok(formats) => formats,
            Err(e) => {
                hbb_common::log::warn!("FuntiDesk camera: no format list: {}", e);
                return;
            }
        };
        hbb_common::log::info!("FuntiDesk camera formats: {:?}", formats);
        let rank = |f: FrameFormat| match f {
            // NV12 first: the camera's native format under Media Foundation;
            // with MJPEG a laptop camera opened at 1 fps and gave no frames.
            FrameFormat::NV12 => 3,
            FrameFormat::MJPEG => 2,
            FrameFormat::YUYV => 1,
            _ => 0,
        };
        let best = formats
            .iter()
            .filter(|f| f.frame_rate() >= 15 && rank(f.format()) > 0)
            .max_by_key(|f| {
                (
                    f.width() * f.height(),
                    rank(f.format()),
                    f.frame_rate().min(30),
                )
            });
        if let Some(best) = best {
            match camera.set_camera_requset(RequestedFormat::new::<RgbAFormat>(
                RequestedFormatType::Exact(*best),
            )) {
                Ok(format) => hbb_common::log::info!("FuntiDesk camera format: {:?}", format),
                Err(e) => hbb_common::log::warn!("FuntiDesk camera: cannot set {:?}: {}", best, e),
            }
        }
    }

    pub fn get_camera_resolution(index: usize) -> ResultType<Resolution> {
        let index = CameraIndex::Index(index as u32);
        let camera = Self::create_camera(&index)?;
        let resolution = camera.resolution();
        Ok(Resolution {
            width: resolution.width() as i32,
            height: resolution.height() as i32,
            ..Default::default()
        })
    }

    pub fn get_sync_cameras() -> Vec<DisplayInfo> {
        SYNC_CAMERA_DISPLAYS.lock().unwrap().clone()
    }

    pub fn get_capturer(current: usize) -> ResultType<Box<dyn TraitCapturer>> {
        Ok(Box::new(CameraCapturer::new(current)?))
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
impl Cameras {
    pub fn all_info() -> ResultType<Vec<DisplayInfo>> {
        return Ok(Vec::new());
    }

    pub fn exists(_index: usize) -> bool {
        false
    }

    pub fn get_camera_resolution(_index: usize) -> ResultType<Resolution> {
        bail!(CAMERA_NOT_SUPPORTED);
    }

    pub fn get_sync_cameras() -> Vec<DisplayInfo> {
        vec![]
    }

    pub fn get_capturer(_current: usize) -> ResultType<Box<dyn TraitCapturer>> {
        bail!(CAMERA_NOT_SUPPORTED);
    }
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
pub struct CameraCapturer {
    // FUNTIDESK: frames come from the reading thread (RGBA, width, height).
    rx: mpsc::Receiver<Result<(Vec<u8>, usize, usize), String>>,
    stop: Arc<AtomicBool>,
    started: Instant,
    got_frame: bool,
    width: usize,
    height: usize,
    data: Vec<u8>,
    last_data: Vec<u8>, // for faster compare and copy
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
impl Drop for CameraCapturer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
pub struct CameraCapturer;

impl CameraCapturer {
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    fn new(current: usize) -> ResultType<Self> {
        // One slot: a slow encoder gets the newest frame, older ones drop.
        let (tx, rx) = mpsc::sync_channel(1);
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        std::thread::Builder::new()
            .name(format!("funti-camera{current}"))
            .spawn(move || Self::read_frames(current, tx, thread_stop))?;
        Ok(CameraCapturer {
            rx,
            stop,
            started: Instant::now(),
            got_frame: false,
            width: 0,
            height: 0,
            data: Vec::new(),
            last_data: Vec::new(),
        })
    }

    // FUNTIDESK: the camera is created, opened and read on this thread only.
    // A read that blocks forever leaves just this thread waiting; the capturer
    // and the video service go on (see FUNTI_NO_FRAME_TIMEOUT).
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    fn read_frames(
        current: usize,
        tx: mpsc::SyncSender<Result<(Vec<u8>, usize, usize), String>>,
        stop: Arc<AtomicBool>,
    ) {
        let index = CameraIndex::Index(current as u32);
        let mut camera = match Cameras::create_camera(&index) {
            Ok(camera) => camera,
            Err(e) => {
                tx.send(Err(e.to_string())).ok();
                return;
            }
        };
        if let Err(e) = camera.open_stream() {
            tx.send(Err(format!("Camera open stream error: {}", e))).ok();
            return;
        }
        hbb_common::log::info!("FuntiDesk camera{}: stream open, {:?}", current, camera.camera_format());
        let mut first = true;
        while !stop.load(Ordering::SeqCst) {
            let frame = match camera.frame() {
                Ok(buffer) => match buffer.decode_image::<RgbAFormat>() {
                    Ok(decoded) => Ok((
                        decoded.as_raw().to_vec(),
                        decoded.width() as usize,
                        decoded.height() as usize,
                    )),
                    Err(e) => Err(format!("Camera frame decode error: {}", e)),
                },
                Err(e) => Err(format!("Camera frame error: {}", e)),
            };
            if first && frame.is_ok() {
                hbb_common::log::info!("FuntiDesk camera{}: first frame", current);
                first = false;
            }
            let failed = frame.is_err();
            match tx.try_send(frame) {
                Ok(()) | Err(mpsc::TrySendError::Full(_)) => {}
                Err(mpsc::TrySendError::Disconnected(_)) => break,
            }
            if failed {
                break;
            }
        }
        camera.stop_stream().ok();
        hbb_common::log::info!("FuntiDesk camera{}: reading stopped", current);
    }

    #[allow(dead_code)]
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    fn new(_current: usize) -> ResultType<Self> {
        bail!(CAMERA_NOT_SUPPORTED);
    }
}

impl TraitCapturer for CameraCapturer {
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    fn frame<'a>(&'a mut self, timeout: std::time::Duration) -> std::io::Result<Frame<'a>> {
        match self.rx.recv_timeout(timeout) {
            Ok(Ok((data, width, height))) => {
                self.got_frame = true;
                self.data = data;
                self.width = width;
                self.height = height;
                crate::would_block_if_equal(&mut self.last_data, &self.data)?;
                Ok(Frame::PixelBuffer(PixelBuffer::new(
                    &self.data,
                    Pixfmt::RGBA,
                    self.width,
                    self.height,
                )))
            }
            Ok(Err(e)) => Err(io::Error::new(io::ErrorKind::Other, e)),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if !self.got_frame && self.started.elapsed() > FUNTI_NO_FRAME_TIMEOUT {
                    Err(io::Error::new(
                        io::ErrorKind::Other,
                        "Camera gives no image (busy, blocked in privacy settings, or unsupported mode)",
                    ))
                } else {
                    Err(io::ErrorKind::WouldBlock.into())
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(io::Error::new(
                io::ErrorKind::Other,
                "Camera reading stopped",
            )),
        }
    }

    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    fn frame<'a>(&'a mut self, _timeout: std::time::Duration) -> std::io::Result<Frame<'a>> {
        Err(io::Error::new(
            io::ErrorKind::Other,
            CAMERA_NOT_SUPPORTED.to_string(),
        ))
    }

    #[cfg(windows)]
    fn is_gdi(&self) -> bool {
        true
    }

    #[cfg(windows)]
    fn set_gdi(&mut self) -> bool {
        true
    }

    #[cfg(feature = "vram")]
    fn device(&self) -> AdapterDevice {
        AdapterDevice::default()
    }

    #[cfg(feature = "vram")]
    fn set_output_texture(&mut self, _texture: bool) {}
}
