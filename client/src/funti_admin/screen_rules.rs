//! FUNTIDESK (ADR-024, stage 3a): a still picture of the screen for the
//! workplace — the request and the answer. Only std and serde_json here, so
//! this file is also built and tested on its own.

use serde_json::{json, Value};

/// The owner of the computer turns pictures off with this option ("Y").
pub const OPTION_DISABLE: &str = "funti-disable-screen-preview";

const WIDTH_MIN: u32 = 160;
const WIDTH_MAX: u32 = 1280;
const WIDTH_DEFAULT: u32 = 640;
/// JPEG quality: text stays readable at the tile size.
pub const QUALITY: u8 = 60;

/// `{"op":"screen","width":640}` → the width of the picture, bounded.
pub fn parse_width(v: &Value) -> u32 {
    v["width"]
        .as_u64()
        .map_or(WIDTH_DEFAULT, |w| w.min(u32::MAX as u64) as u32)
        .clamp(WIDTH_MIN, WIDTH_MAX)
}

/// The size of a picture `width` wide with the proportions of the screen;
/// never larger than the screen.
pub fn scaled(screen_w: u32, screen_h: u32, width: u32) -> (u32, u32) {
    if screen_w == 0 || screen_h == 0 {
        return (0, 0);
    }
    let w = width.min(screen_w);
    let h = ((screen_h as u64 * w as u64 + screen_w as u64 / 2) / screen_w as u64).max(1) as u32;
    (w, h)
}

pub fn allowed(option: &str) -> bool {
    option != "Y"
}

pub fn answer_json(w: u32, h: u32, jpeg_base64: String) -> Value {
    json!({"op": "screen", "w": w, "h": h, "jpeg": jpeg_base64})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths() {
        assert_eq!(parse_width(&json!({"op": "screen"})), WIDTH_DEFAULT);
        assert_eq!(parse_width(&json!({"op": "screen", "width": 10})), WIDTH_MIN);
        assert_eq!(parse_width(&json!({"op": "screen", "width": 99999})), WIDTH_MAX);
        assert_eq!(parse_width(&json!({"op": "screen", "width": u64::MAX})), WIDTH_MAX);
        assert_eq!(parse_width(&json!({"op": "screen", "width": 320})), 320);
    }

    #[test]
    fn sizes() {
        assert_eq!(scaled(1920, 1080, 640), (640, 360));
        assert_eq!(scaled(2560, 1600, 320), (320, 200));
        assert_eq!(scaled(800, 600, 1280), (800, 600));
        assert_eq!(scaled(0, 600, 640), (0, 0));
        assert_eq!(scaled(10000, 1, 160), (160, 1));
    }

    #[test]
    fn switch() {
        assert!(allowed(""));
        assert!(allowed("N"));
        assert!(!allowed("Y"));
    }
}
