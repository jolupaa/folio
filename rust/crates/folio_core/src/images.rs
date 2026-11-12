//! Imágenes: detección de formato y dimensiones, y procesado de capturas (orientación EXIF,
//! giro, recorte, reducción y JPEG calidad 90). Puro Rust (crate `image`).

use crate::fsutil::{path_string, write_atomic};
use crate::model::{CropRect, ImageInfo};
use anyhow::{anyhow, bail, Context};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, RgbImage};
use std::io::{BufReader, Cursor, Read};
use std::path::Path;

/// Calidad JPEG de las imágenes procesadas.
pub const JPEG_QUALITY: u8 = 90;

/// Información básica de una imagen sin decodificar los píxeles.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProbedImage {
    pub mime: &'static str,
    /// Extensiones válidas (la primera es la preferida).
    pub exts: &'static [&'static str],
    /// Dimensiones ya orientadas (EXIF aplicado). None si el formato no se puede decodificar
    /// en Rust (HEIC/HEIF: se guarda tal cual; la plataforma lo muestra).
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub is_jpeg: bool,
}

fn format_info(f: ImageFormat) -> Option<(&'static str, &'static [&'static str])> {
    Some(match f {
        ImageFormat::Jpeg => ("image/jpeg", &["jpg", "jpeg"]),
        ImageFormat::Png => ("image/png", &["png"]),
        ImageFormat::WebP => ("image/webp", &["webp"]),
        ImageFormat::Gif => ("image/gif", &["gif"]),
        _ => return None,
    })
}

/// HEIC/HEIF (fotos de iPhone): caja `ftyp` con marca heic/heix/hevc/mif1/msf1…
fn is_heif(head: &[u8]) -> bool {
    head.len() >= 12
        && &head[4..8] == b"ftyp"
        && matches!(
            &head[8..12],
            b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis" | b"mif1" | b"msf1" | b"avif"
        )
}

fn swaps_axes(o: Orientation) -> bool {
    matches!(
        o,
        Orientation::Rotate90 | Orientation::Rotate270 | Orientation::Rotate90FlipH | Orientation::Rotate270FlipH
    )
}

/// Detecta el formato y las dimensiones orientadas. `Ok(None)` si no es una imagen compatible.
pub fn probe(path: &Path) -> anyhow::Result<Option<ProbedImage>> {
    let mut head = [0u8; 32];
    let n = {
        let mut f = std::fs::File::open(path)
            .with_context(|| format!("No se pudo abrir {}", path.display()))?;
        let mut read = 0;
        while read < head.len() {
            let k = f.read(&mut head[read..])?;
            if k == 0 {
                break;
            }
            read += k;
        }
        read
    };
    if is_heif(&head[..n]) {
        let avif = &head[8..12] == b"avif";
        return Ok(Some(ProbedImage {
            mime: if avif { "image/avif" } else { "image/heic" },
            exts: if avif { &["avif"] } else { &["heic", "heif"] },
            width: None,
            height: None,
            is_jpeg: false,
        }));
    }
    let Ok(format) = image::guess_format(&head[..n]) else { return Ok(None) };
    let Some((mime, exts)) = format_info(format) else { return Ok(None) };
    let file = std::fs::File::open(path)?;
    let reader = ImageReader::with_format(BufReader::new(file), format);
    let Ok(mut decoder) = reader.into_decoder() else { return Ok(None) };
    let (w, h) = decoder.dimensions();
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let (w, h) = if swaps_axes(orientation) { (h, w) } else { (w, h) };
    Ok(Some(ProbedImage {
        mime,
        exts,
        width: Some(w),
        height: Some(h),
        is_jpeg: format == ImageFormat::Jpeg,
    }))
}

/// Decodifica aplicando la orientación EXIF.
pub fn decode_oriented(bytes: &[u8]) -> anyhow::Result<DynamicImage> {
    let reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .context("leer imagen")?;
    if reader.format().and_then(format_info).is_none() {
        bail!("Formato de imagen no compatible (usa JPEG, PNG, WebP o GIF)");
    }
    let mut decoder = reader
        .into_decoder()
        .map_err(|e| anyhow!("No se pudo leer la imagen: {e}"))?;
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let mut img =
        DynamicImage::from_decoder(decoder).map_err(|e| anyhow!("No se pudo decodificar la imagen: {e}"))?;
    img.apply_orientation(orientation);
    Ok(img)
}

/// RGB8 componiendo la transparencia sobre blanco (JPEG no admite canal alfa).
fn to_rgb_on_white(img: &DynamicImage) -> RgbImage {
    if !img.color().has_alpha() {
        return img.to_rgb8();
    }
    let rgba = img.to_rgba8();
    let mut out = RgbImage::new(rgba.width(), rgba.height());
    for (dst, src) in out.pixels_mut().zip(rgba.pixels()) {
        let a = src[3] as u32;
        for c in 0..3 {
            dst[c] = ((src[c] as u32 * a + 255 * (255 - a) + 127) / 255) as u8;
        }
    }
    out
}

/// Codifica como JPEG (calidad 90).
pub fn encode_jpeg(img: &DynamicImage) -> anyhow::Result<Vec<u8>> {
    let rgb = to_rgb_on_white(img);
    let mut buf = Vec::with_capacity((rgb.width() * rgb.height()) as usize / 4);
    let encoder = JpegEncoder::new_with_quality(&mut buf, JPEG_QUALITY);
    DynamicImage::ImageRgb8(rgb)
        .write_with_encoder(encoder)
        .map_err(|e| anyhow!("No se pudo codificar la imagen: {e}"))?;
    Ok(buf)
}

/// Rectángulo de recorte en píxeles a partir de coordenadas normalizadas (acotadas a la imagen).
fn crop_pixels(c: &CropRect, w: u32, h: u32) -> anyhow::Result<(u32, u32, u32, u32)> {
    let vals = [c.x, c.y, c.w, c.h];
    if vals.iter().any(|v| !v.is_finite()) {
        bail!("Recorte no válido");
    }
    let x0 = c.x.clamp(0.0, 1.0);
    let y0 = c.y.clamp(0.0, 1.0);
    let x1 = (c.x + c.w).clamp(0.0, 1.0);
    let y1 = (c.y + c.h).clamp(0.0, 1.0);
    if x1 <= x0 || y1 <= y0 {
        bail!("Recorte no válido: el área está vacía");
    }
    let px0 = ((x0 * w as f64).round() as u32).min(w.saturating_sub(1));
    let py0 = ((y0 * h as f64).round() as u32).min(h.saturating_sub(1));
    let px1 = ((x1 * w as f64).round() as u32).clamp(px0 + 1, w);
    let py1 = ((y1 * h as f64).round() as u32).clamp(py0 + 1, h);
    Ok((px0, py0, px1 - px0, py1 - py0))
}

/// Normaliza orientación EXIF, gira `rotate_quarter_turns`×90° en sentido horario, recorta
/// (`crop` normalizado sobre la imagen YA girada), limita el lado mayor a `max_dimension`
/// (0 = sin límite) y escribe un JPEG calidad 90 en `output_path`.
pub fn process_image(
    input_path: &Path,
    output_path: &Path,
    rotate_quarter_turns: i32,
    crop: Option<&CropRect>,
    max_dimension: u32,
) -> anyhow::Result<ImageInfo> {
    let bytes = std::fs::read(input_path)
        .with_context(|| format!("No se pudo leer la imagen {}", input_path.display()))?;
    let mut img = decode_oriented(&bytes)?;
    drop(bytes);
    img = match rotate_quarter_turns.rem_euclid(4) {
        1 => img.rotate90(),
        2 => img.rotate180(),
        3 => img.rotate270(),
        _ => img,
    };
    if let Some(c) = crop {
        let (x, y, w, h) = crop_pixels(c, img.width(), img.height())?;
        if (x, y, w, h) != (0, 0, img.width(), img.height()) {
            img = img.crop_imm(x, y, w, h);
        }
    }
    if max_dimension > 0 && img.width().max(img.height()) > max_dimension {
        img = img.resize(max_dimension, max_dimension, FilterType::CatmullRom);
    }
    let jpeg = encode_jpeg(&img)?;
    write_atomic(output_path, &jpeg)?;
    Ok(ImageInfo {
        path: path_string(output_path),
        width: img.width(),
        height: img.height(),
        size_bytes: jpeg.len() as i64,
    })
}

/// Copia una imagen como JPEG en `dst`: tal cual si ya es JPEG; si no, la recodifica.
/// Devuelve (bytes escritos, ancho, alto) — dimensiones None si no se pudieron leer.
pub fn store_as_jpeg(src: &Path, dst: &Path) -> anyhow::Result<(i64, Option<u32>, Option<u32>)> {
    let probed = probe(src)?.ok_or_else(|| anyhow!("Formato de imagen no compatible"))?;
    if probed.is_jpeg {
        let bytes = std::fs::read(src).with_context(|| format!("leer {}", src.display()))?;
        write_atomic(dst, &bytes)?;
        return Ok((bytes.len() as i64, probed.width, probed.height));
    }
    if probed.width.is_none() {
        bail!("Formato de imagen no compatible (usa JPEG, PNG, WebP o GIF)");
    }
    let bytes = std::fs::read(src).with_context(|| format!("leer {}", src.display()))?;
    let img = decode_oriented(&bytes)?;
    let jpeg = encode_jpeg(&img)?;
    write_atomic(dst, &jpeg)?;
    Ok((jpeg.len() as i64, Some(img.width()), Some(img.height())))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use image::{ImageEncoder, Rgb, RgbImage, Rgba, RgbaImage};

    /// Bloque TIFF mínimo con la etiqueta Orientation (0x0112).
    pub(crate) fn exif_orientation(value: u16) -> Vec<u8> {
        let mut v = b"MM\x00\x2a\x00\x00\x00\x08".to_vec();
        v.extend_from_slice(&1u16.to_be_bytes());
        v.extend_from_slice(&0x0112u16.to_be_bytes());
        v.extend_from_slice(&3u16.to_be_bytes());
        v.extend_from_slice(&1u32.to_be_bytes());
        v.extend_from_slice(&value.to_be_bytes());
        v.extend_from_slice(&[0, 0]);
        v.extend_from_slice(&0u32.to_be_bytes());
        v
    }

    /// Imagen de prueba: mitad izquierda roja, mitad derecha azul.
    pub(crate) fn two_color(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, _| if x < w / 2 { Rgb([255, 0, 0]) } else { Rgb([0, 0, 255]) })
    }

    pub(crate) fn write_jpeg(path: &Path, img: &RgbImage, exif: Option<Vec<u8>>) {
        let mut buf = Vec::new();
        let mut enc = JpegEncoder::new_with_quality(&mut buf, 95);
        if let Some(e) = exif {
            enc.set_exif_metadata(e).unwrap();
        }
        enc.write_image(img.as_raw(), img.width(), img.height(), image::ExtendedColorType::Rgb8)
            .unwrap();
        std::fs::write(path, buf).unwrap();
    }

    fn is_red(p: &Rgb<u8>) -> bool {
        p[0] > 200 && p[2] < 60
    }
    fn is_blue(p: &Rgb<u8>) -> bool {
        p[2] > 200 && p[0] < 60
    }

    #[test]
    fn rotates_crops_and_resizes() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("in.jpg");
        write_jpeg(&src, &two_color(400, 200), None);
        let out = d.path().join("out/out.jpg");

        // Sin cambios salvo recodificar.
        let info = process_image(&src, &out, 0, None, 0).unwrap();
        assert_eq!((info.width, info.height), (400, 200));
        assert_eq!(info.size_bytes as u64, std::fs::metadata(&out).unwrap().len());

        // Giro horario de 90°: la mitad roja (izquierda) pasa a estar arriba.
        let info = process_image(&src, &out, 1, None, 0).unwrap();
        assert_eq!((info.width, info.height), (200, 400));
        let img = image::open(&out).unwrap().to_rgb8();
        assert!(is_red(img.get_pixel(100, 50)));
        assert!(is_blue(img.get_pixel(100, 350)));

        // −1 = 270° horario: la mitad roja pasa abajo.
        let info = process_image(&src, &out, -1, None, 0).unwrap();
        assert_eq!((info.width, info.height), (200, 400));
        let img = image::open(&out).unwrap().to_rgb8();
        assert!(is_red(img.get_pixel(100, 350)));

        // Recorte sobre la imagen YA girada: mitad superior (roja) de la imagen 200×400.
        let crop = CropRect { x: 0.0, y: 0.0, w: 1.0, h: 0.5 };
        let info = process_image(&src, &out, 1, Some(&crop), 0).unwrap();
        assert_eq!((info.width, info.height), (200, 200));
        let img = image::open(&out).unwrap().to_rgb8();
        assert!(is_red(img.get_pixel(100, 100)));
        assert!(is_red(img.get_pixel(100, 190)));

        // Reducción del lado mayor conservando proporción.
        let info = process_image(&src, &out, 0, None, 100).unwrap();
        assert_eq!((info.width, info.height), (100, 50));

        // Recorte vacío → error legible.
        let bad = CropRect { x: 0.5, y: 0.5, w: 0.0, h: 0.2 };
        assert!(process_image(&src, &out, 0, Some(&bad), 0).is_err());
    }

    #[test]
    fn applies_exif_orientation() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("exif.jpg");
        // Orientación 6 = girar 90° horario para mostrar.
        write_jpeg(&src, &two_color(400, 200), Some(exif_orientation(6)));
        let p = probe(&src).unwrap().unwrap();
        assert_eq!((p.width, p.height), (Some(200), Some(400)));
        assert!(p.is_jpeg);
        let out = d.path().join("o.jpg");
        let info = process_image(&src, &out, 0, None, 0).unwrap();
        assert_eq!((info.width, info.height), (200, 400));
        let img = image::open(&out).unwrap().to_rgb8();
        assert!(is_red(img.get_pixel(100, 50)), "EXIF 6 debe dejar la mitad roja arriba");
        // El JPEG resultante ya no lleva la orientación: se ve igual sin aplicar EXIF.
        let p = probe(&out).unwrap().unwrap();
        assert_eq!((p.width, p.height), (Some(200), Some(400)));
    }

    #[test]
    fn png_with_alpha_is_flattened_on_white_and_probe_rejects_garbage() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("a.png");
        let img = RgbaImage::from_pixel(10, 10, Rgba([0, 0, 0, 0]));
        img.save(&src).unwrap();
        let p = probe(&src).unwrap().unwrap();
        assert_eq!(p.mime, "image/png");
        let out = d.path().join("a.jpg");
        process_image(&src, &out, 0, None, 0).unwrap();
        let px = *image::open(&out).unwrap().to_rgb8().get_pixel(5, 5);
        assert!(px[0] > 240 && px[1] > 240 && px[2] > 240, "{px:?}");

        let junk = d.path().join("x.jpg");
        std::fs::write(&junk, b"esto no es una imagen").unwrap();
        assert!(probe(&junk).unwrap().is_none());
        assert!(process_image(&junk, &out, 0, None, 0).is_err());
    }
}
