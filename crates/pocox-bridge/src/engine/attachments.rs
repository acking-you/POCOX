//! Bounded local attachment reads and native image preparation.
use std::{
    fs::File,
    io::{Cursor, Read},
    path::Path,
};

use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use image::{
    codecs::jpeg::JpegEncoder, imageops::FilterType, metadata::Orientation, DynamicImage,
    ImageDecoder, ImageFormat, ImageReader, Limits,
};

const MAX_INPUT: u64 = 32 << 20;
const MAX_PIXELS: u64 = 32_000_000;
const MAX_DECODED: u64 = 128 << 20;
const MAX_EDGE: u32 = 1568;
const PASSTHROUGH: usize = 1 << 20;

/// Prepared image bytes and the wire form, computed once outside Dart.
pub struct PreparedImage {
    /// Encoded original or JPEG, suitable for the preview and native saving.
    pub bytes: Vec<u8>,
    /// MIME type of the encoded bytes.
    pub mime: String,
    /// Encoded width.
    pub width: u32,
    /// Encoded height.
    pub height: u32,
    /// Exact data URL retained for explicit retries of the same send.
    pub data_url: String,
}

/// Read only an explicitly selected local regular file, with a byte limit
/// enforced on the open handle and again while reading if it grows.
pub fn read_file(path: &Path) -> Result<Vec<u8>> {
    ensure!(path.is_absolute(), "attachment path must be local and absolute");
    let file = File::open(path).context("opening selected attachment")?;
    let metadata = file.metadata()?;
    ensure!(metadata.is_file(), "attachment is not a regular file");
    ensure!(metadata.len() <= MAX_INPUT, "attachment exceeds 32 MiB");
    let mut bytes = Vec::new();
    file.take(MAX_INPUT + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= MAX_INPUT, "attachment exceeds 32 MiB");
    Ok(bytes)
}

fn dimensions(width: u32, height: u32, bytes: u64) -> Result<()> {
    ensure!(
        width > 0 && height > 0 && u64::from(width) * u64::from(height) <= MAX_PIXELS,
        "image exceeds the 32 megapixel decode limit"
    );
    ensure!(bytes <= MAX_DECODED, "image exceeds the 128 MiB decode limit");
    Ok(())
}

/// Decode the first frame, preserve small native formats, otherwise orient,
/// resize and composite over white before encoding an 85-quality JPEG.
pub fn prepare(bytes: Vec<u8>) -> Result<PreparedImage> {
    ensure!(bytes.len() as u64 <= MAX_INPUT, "image exceeds 32 MiB");
    let mut reader = ImageReader::new(Cursor::new(&bytes)).with_guessed_format()?;
    let format = reader.format().context("not a decodable image")?;
    let mut limits = Limits::default();
    limits.max_alloc = Some(MAX_DECODED);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().context("reading image header")?;
    let (width, height) = decoder.dimensions();
    dimensions(width, height, decoder.total_bytes())?;
    let orientation = decoder.orientation()?;
    let mut decoded = DynamicImage::from_decoder(decoder).context("decoding image")?;
    let passthrough = matches!(
        format,
        ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::Gif | ImageFormat::WebP
    ) && orientation == Orientation::NoTransforms
        && width.max(height) <= MAX_EDGE
        && bytes.len() <= PASSTHROUGH;
    let (bytes, mime) = if passthrough {
        (bytes, format.to_mime_type().to_string())
    } else {
        decoded.apply_orientation(orientation);
        if decoded.width().max(decoded.height()) > MAX_EDGE {
            decoded = decoded.resize(MAX_EDGE, MAX_EDGE, FilterType::Triangle);
        }
        let rgba = decoded.into_rgba8();
        let mut rgb = image::RgbImage::new(rgba.width(), rgba.height());
        for (source, target) in rgba.pixels().zip(rgb.pixels_mut()) {
            let alpha = u32::from(source[3]);
            for channel in 0..3 {
                target[channel] =
                    ((u32::from(source[channel]) * alpha + 255 * (255 - alpha) + 127) / 255) as u8;
            }
        }
        let mut output = Vec::new();
        JpegEncoder::new_with_quality(&mut output, 85).encode_image(&rgb)?;
        return Ok(finish(output, "image/jpeg".into(), rgb.width(), rgb.height()));
    };
    Ok(finish(bytes, mime, width, height))
}

fn finish(bytes: Vec<u8>, mime: String, width: u32, height: u32) -> PreparedImage {
    let data_url = format!("data:{mime};base64,{}", STANDARD.encode(&bytes));
    PreparedImage {
        bytes,
        mime,
        width,
        height,
        data_url,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn png(width: u32, height: u32, alpha: u8) -> Vec<u8> {
        let image = image::RgbaImage::from_pixel(width, height, image::Rgba([200, 40, 40, alpha]));
        let mut bytes = Cursor::new(Vec::new());
        image.write_to(&mut bytes, ImageFormat::Png).unwrap();
        bytes.into_inner()
    }
    #[test]
    fn small_screenshots_pass_through_and_large_transparency_composites_white() {
        let bytes = png(6, 4, 255);
        let small = prepare(bytes.clone()).unwrap();
        assert_eq!(small.bytes, bytes);
        assert_eq!(small.mime, "image/png");
        assert_eq!(small.data_url, format!("data:image/png;base64,{}", STANDARD.encode(bytes)));
        let large = prepare(png(MAX_EDGE * 2, 100, 0)).unwrap();
        assert_eq!((large.width, large.height), (MAX_EDGE, 50));
        let decoded = image::load_from_memory(&large.bytes).unwrap().into_rgb8();
        assert!(decoded.get_pixel(0, 0).0.iter().all(|value| *value > 240));
    }
    #[test]
    fn exif_orientation_is_baked_and_large_animations_use_the_first_frame() {
        let mut jpeg = Vec::new();
        JpegEncoder::new(&mut jpeg)
            .encode_image(&image::RgbImage::new(3, 2))
            .unwrap();
        let exif = b"Exif\0\0II\x2a\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0\x06\0\0\0\0\0\0\0";
        let mut tagged = vec![0xff, 0xd8, 0xff, 0xe1];
        tagged.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
        tagged.extend_from_slice(exif);
        tagged.extend_from_slice(&jpeg[2..]);
        let oriented = prepare(tagged).unwrap();
        assert_eq!((oriented.width, oriented.height), (2, 3));
        let mut gif = Vec::new();
        {
            let mut encoder = image::codecs::gif::GifEncoder::new(&mut gif);
            for pixel in [[0, 240, 0, 255], [240, 0, 0, 255]] {
                encoder
                    .encode_frame(image::Frame::new(image::RgbaImage::from_pixel(
                        MAX_EDGE + 1,
                        2,
                        image::Rgba(pixel),
                    )))
                    .unwrap();
            }
        }
        let first = prepare(gif).unwrap();
        assert_eq!(first.width, MAX_EDGE);
        let decoded = image::load_from_memory(&first.bytes).unwrap().into_rgb8();
        let pixel = decoded.get_pixel(0, 0);
        assert!(pixel[1] > 200 && pixel[0] < 40);
    }

    #[test]
    fn rejects_corrupt_images_and_excessive_decoded_allocations() {
        assert!(prepare(b"not an image".to_vec()).is_err());
        assert!(dimensions(100_000, 100_000, 0).is_err());
        assert!(dimensions(1, 1, MAX_DECODED + 1).is_err());
        let dir = tempfile::tempdir().unwrap();
        assert!(read_file(dir.path()).is_err());
        let path = dir.path().join("large");
        File::create(&path).unwrap().set_len(MAX_INPUT + 1).unwrap();
        assert!(read_file(&path).is_err());
    }
}
