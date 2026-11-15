//! FUNTIDESK (ADR-024, stage 3a): a still picture of the main screen, by
//! GDI so that it does not take the screen capture of an open session.

use super::screen_rules;
use hbb_common::base64::{engine::general_purpose::STANDARD, Engine};
use image::{codecs::jpeg::JpegEncoder, imageops, ColorType, RgbaImage};
use scrap::{dxgi::gdi::CapturerGDI, Display};

/// The JSON answer, or Err(translation key of the reason).
pub fn picture(width: u32) -> Result<String, &'static str> {
    // Only what is attached: no virtual display is added for a picture.
    let mut displays = Display::all().map_err(|_| "funti-admin-screen-failed")?;
    let primary = displays.iter().position(|d| d.is_primary()).unwrap_or(0);
    if displays.is_empty() {
        return Err("funti-admin-screen-failed");
    }
    let display = displays.swap_remove(primary);
    let (sw, sh) = (display.width() as u32, display.height() as u32);
    let name: Vec<u16> = display.name().encode_utf16().chain(std::iter::once(0)).collect();
    let capturer = CapturerGDI::new(&name, sw as i32, sh as i32).map_err(|e| {
        hbb_common::log::info!("FuntiDesk screen picture: {}", e);
        "funti-admin-screen-failed"
    })?;
    let mut bgra = Vec::new();
    capturer.frame(&mut bgra).map_err(|e| {
        hbb_common::log::info!("FuntiDesk screen picture: {}", e);
        "funti-admin-screen-failed"
    })?;
    for px in bgra.chunks_exact_mut(4) {
        px.swap(0, 2);
        px[3] = 255;
    }
    let full = RgbaImage::from_raw(sw, sh, bgra).ok_or("funti-admin-screen-failed")?;
    let (w, h) = screen_rules::scaled(sw, sh, width);
    let small = imageops::thumbnail(&full, w, h);
    let rgb: Vec<u8> = small.pixels().flat_map(|p| [p[0], p[1], p[2]]).collect();
    let mut jpeg = Vec::new();
    JpegEncoder::new_with_quality(&mut jpeg, screen_rules::QUALITY)
        .encode(&rgb, w, h, ColorType::Rgb8)
        .map_err(|_| "funti-admin-screen-failed")?;
    Ok(screen_rules::answer_json(w, h, STANDARD.encode(jpeg)).to_string())
}
