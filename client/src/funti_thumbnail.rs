//! FUNTIDESK (ADR-017): small JPEG previews of pictures for the file
//! transfer window. Made on the computer that has the file, in the user's
//! process that already reads its folders; only the preview is sent.

/// Requested size is clamped to this range (pixels, longer side).
pub const MIN_SIDE: u32 = 32;
pub const MAX_SIDE: u32 = 256;
/// Bigger files and pictures are not decoded.
pub const MAX_FILE_SIZE: u64 = 50 * 1024 * 1024;
pub const MAX_PIXELS: u64 = 40_000_000;
/// The preview sent back is not larger than this.
pub const MAX_JPEG_SIZE: usize = 32 * 1024;

const EXTENSIONS: [&str; 6] = ["jpg", "jpeg", "png", "gif", "bmp", "webp"];

pub fn is_picture(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| EXTENSIONS.contains(&e.to_lowercase().as_str()))
}

/// JPEG bytes of the preview, or a short reason why there is none.
#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
pub fn make(path: &str, max_side: i32) -> Result<Vec<u8>, String> {
    use image::{codecs::jpeg::JpegEncoder, io::Reader, DynamicImage, Rgb, RgbImage};
    use std::io::Read;

    if !is_picture(path) {
        return Err("not a picture".to_owned());
    }
    let side = (max_side.max(0) as u32).clamp(MIN_SIDE, MAX_SIDE);
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_file() {
        return Err("not a file".to_owned());
    }
    if meta.len() > MAX_FILE_SIZE {
        return Err("file too big".to_owned());
    }
    let mut data = Vec::with_capacity(meta.len() as usize);
    std::fs::File::open(path)
        .and_then(|f| f.take(MAX_FILE_SIZE + 1).read_to_end(&mut data))
        .map_err(|e| e.to_string())?;
    if data.len() as u64 > MAX_FILE_SIZE {
        return Err("file too big".to_owned());
    }
    let reader = Reader::new(std::io::Cursor::new(&data[..]))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let (w, h) = reader.into_dimensions().map_err(|e| e.to_string())?;
    if w == 0 || h == 0 || w as u64 * h as u64 > MAX_PIXELS {
        return Err("picture too big".to_owned());
    }
    let mut reader = Reader::new(std::io::Cursor::new(&data[..]))
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let mut limits = image::io::Limits::default();
    limits.max_image_width = Some(w);
    limits.max_image_height = Some(h);
    limits.max_alloc = Some(MAX_PIXELS * 8);
    reader.limits(limits);
    let img = reader.decode().map_err(|e| e.to_string())?;
    let img = match jpeg_orientation(&data) {
        2 => img.fliph(),
        3 => img.rotate180(),
        4 => img.flipv(),
        5 => img.rotate90().fliph(),
        6 => img.rotate90(),
        7 => img.rotate270().fliph(),
        8 => img.rotate270(),
        _ => img,
    };
    let small = img.thumbnail(side, side).into_rgba8();
    // Transparent parts become white, as in Explorer.
    let mut rgb = RgbImage::new(small.width(), small.height());
    for (x, y, p) in small.enumerate_pixels() {
        let a = p[3] as u32;
        let mix = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        rgb.put_pixel(x, y, Rgb([mix(p[0]), mix(p[1]), mix(p[2])]));
    }
    let rgb = DynamicImage::ImageRgb8(rgb);
    for quality in [80u8, 60, 40] {
        let mut out = Vec::new();
        JpegEncoder::new_with_quality(&mut out, quality)
            .encode_image(&rgb)
            .map_err(|e| e.to_string())?;
        if out.len() <= MAX_JPEG_SIZE {
            return Ok(out);
        }
    }
    Err("preview too big".to_owned())
}

#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
pub fn make(_path: &str, _max_side: i32) -> Result<Vec<u8>, String> {
    Err("not supported".to_owned())
}

/// EXIF orientation (1..8) of a JPEG, 1 when there is none: phone photos
/// are stored sideways with this tag.
pub fn jpeg_orientation(data: &[u8]) -> u16 {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return 1;
    }
    let mut i = 2;
    while i + 4 <= data.len() && data[i] == 0xFF {
        let marker = data[i + 1];
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = u16::from_be_bytes([data[i + 2], data[i + 3]]) as usize;
        if len < 2 || i + 2 + len > data.len() {
            break;
        }
        let seg = &data[i + 4..i + 2 + len];
        if marker == 0xE1 && seg.len() > 6 && &seg[..6] == b"Exif\0\0" {
            return tiff_orientation(&seg[6..]).unwrap_or(1);
        }
        i += 2 + len;
    }
    1
}

fn tiff_orientation(t: &[u8]) -> Option<u16> {
    let le = match t.get(..2)? {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let u16_at = |o: usize| -> Option<u16> {
        let b = t.get(o..o + 2)?;
        Some(if le {
            u16::from_le_bytes([b[0], b[1]])
        } else {
            u16::from_be_bytes([b[0], b[1]])
        })
    };
    let u32_at = |o: usize| -> Option<u32> {
        let b = t.get(o..o + 4)?;
        Some(if le {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]])
        } else {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]])
        })
    };
    let ifd = u32_at(4)? as usize;
    let count = u16_at(ifd)? as usize;
    for n in 0..count.min(256) {
        let e = ifd + 2 + n * 12;
        if u16_at(e)? == 0x0112 {
            let v = u16_at(e + 8)?;
            return (1..=8).contains(&v).then_some(v);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exif_jpeg(orientation: u16, le: bool) -> Vec<u8> {
        let w16 = |v: u16| if le { v.to_le_bytes() } else { v.to_be_bytes() };
        let w32 = |v: u32| if le { v.to_le_bytes() } else { v.to_be_bytes() };
        let mut tiff = Vec::new();
        tiff.extend_from_slice(if le { b"II" } else { b"MM" });
        tiff.extend_from_slice(&w16(42));
        tiff.extend_from_slice(&w32(8));
        tiff.extend_from_slice(&w16(1));
        tiff.extend_from_slice(&w16(0x0112));
        tiff.extend_from_slice(&w16(3));
        tiff.extend_from_slice(&w32(1));
        tiff.extend_from_slice(&w16(orientation));
        tiff.extend_from_slice(&[0, 0]);
        tiff.extend_from_slice(&w32(0));
        let mut seg = b"Exif\0\0".to_vec();
        seg.extend_from_slice(&tiff);
        let mut out = vec![0xFF, 0xD8, 0xFF, 0xE1];
        out.extend_from_slice(&((seg.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(&seg);
        out.extend_from_slice(&[0xFF, 0xD9]);
        out
    }

    fn png_header(w: u32, h: u32) -> Vec<u8> {
        fn crc(data: &[u8]) -> u32 {
            let mut c = !0u32;
            for &b in data {
                c ^= b as u32;
                for _ in 0..8 {
                    c = if c & 1 != 0 {
                        0xEDB8_8320 ^ (c >> 1)
                    } else {
                        c >> 1
                    };
                }
            }
            !c
        }
        let mut ihdr = b"IHDR".to_vec();
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
        let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
        for chunk in [ihdr, b"IDAT".to_vec(), b"IEND".to_vec()] {
            out.extend_from_slice(&(chunk.len() as u32 - 4).to_be_bytes());
            out.extend_from_slice(&chunk);
            out.extend_from_slice(&crc(&chunk).to_be_bytes());
        }
        out
    }

    #[test]
    fn orientation_is_read_in_both_byte_orders() {
        assert_eq!(jpeg_orientation(&exif_jpeg(6, true)), 6);
        assert_eq!(jpeg_orientation(&exif_jpeg(8, false)), 8);
        assert_eq!(jpeg_orientation(&exif_jpeg(9, true)), 1);
        assert_eq!(jpeg_orientation(b"not a jpeg"), 1);
        assert_eq!(jpeg_orientation(&[0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF]), 1);
    }

    #[test]
    fn only_pictures_by_extension() {
        assert!(is_picture(r"C:\Фото\IMG_1.JPG"));
        assert!(is_picture("/home/a/b.webp"));
        assert!(!is_picture("/home/a/b.exe"));
        assert!(!is_picture("/home/a/jpg"));
    }

    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    #[test]
    fn preview_is_small_rotated_and_refuses_junk() {
        let dir = std::env::temp_dir().join(format!("funti-thumb-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // 400x200 PNG with transparency.
        let png = dir.join("a.png");
        image::RgbaImage::from_fn(400, 200, |x, _| image::Rgba([x as u8, 0, 0, 128]))
            .save(&png)
            .unwrap();
        let out = make(png.to_str().unwrap(), 160).unwrap();
        assert!(out.len() <= MAX_JPEG_SIZE);
        let t = image::load_from_memory(&out).unwrap();
        assert_eq!((t.width(), t.height()), (160, 80));
        // A JPEG with orientation 6 comes back turned.
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new(&mut jpeg)
            .encode_image(&image::DynamicImage::ImageRgb8(image::RgbImage::new(
                300, 100,
            )))
            .unwrap();
        let exif = exif_jpeg(6, true);
        let mut rotated = jpeg[..2].to_vec();
        rotated.extend_from_slice(&exif[2..exif.len() - 2]);
        rotated.extend_from_slice(&jpeg[2..]);
        let jpg = dir.join("b.jpg");
        std::fs::write(&jpg, rotated).unwrap();
        let t = image::load_from_memory(&make(jpg.to_str().unwrap(), 9999).unwrap()).unwrap();
        assert_eq!((t.width(), t.height()), (85, 256));
        // A header promising 100 000 x 100 000 pixels is refused before decoding.
        let huge = dir.join("e.png");
        std::fs::write(&huge, png_header(100_000, 100_000)).unwrap();
        assert_eq!(
            make(huge.to_str().unwrap(), 160).unwrap_err(),
            "picture too big"
        );
        // Not a picture, broken picture, folder.
        let bad = dir.join("c.jpg");
        std::fs::write(&bad, b"junk").unwrap();
        assert!(make(bad.to_str().unwrap(), 160).is_err());
        assert!(make(dir.join("d.txt").to_str().unwrap(), 160).is_err());
        assert!(make(dir.to_str().unwrap(), 160).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }
}
