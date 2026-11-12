//! Utilidades de ficheros: nombres seguros, copia con hash, tamaños de directorios.

use anyhow::Context;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// Longitud máxima (en caracteres) de un nombre de fichero guardado.
const MAX_NAME_CHARS: usize = 100;

/// Nombre de fichero seguro para el almacenamiento de la app.
///
/// - Solo el último componente (sin rutas), sin caracteres de control ni reservados.
/// - Si queda vacío se usa `fallback_stem`.
/// - Si la extensión no está en `exts` (en minúsculas, sin punto) se añade `exts[0]`.
/// - Máximo 100 caracteres conservando la extensión.
pub fn sanitize_file_name(name: &str, fallback_stem: &str, exts: &[&str]) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or("");
    let mut cleaned: String = last
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '|' | '?' | '*' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    cleaned = cleaned.trim().trim_matches('.').trim().to_string();
    if cleaned.is_empty() {
        cleaned = fallback_stem.to_string();
    }
    let (stem, ext) = match cleaned.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() && !e.is_empty() && !e.contains(' ') => {
            (s.to_string(), Some(e.to_string()))
        }
        _ => (cleaned.clone(), None),
    };
    let ext_ok = match (&ext, exts.is_empty()) {
        (_, true) => true,
        (Some(e), false) => exts.iter().any(|x| x.eq_ignore_ascii_case(e)),
        (None, false) => false,
    };
    let (stem, ext) = if ext_ok {
        (stem, ext)
    } else {
        // Extensión ausente o ajena: se conserva como parte del nombre y se añade la correcta.
        (cleaned.clone(), exts.first().map(|e| e.to_string()))
    };
    let ext_len = ext.as_ref().map(|e| e.chars().count() + 1).unwrap_or(0);
    let max_stem = MAX_NAME_CHARS.saturating_sub(ext_len).max(1);
    let stem = crate::util::truncate_chars(&stem, max_stem).trim_end().to_string();
    let stem = if stem.is_empty() { fallback_stem.to_string() } else { stem };
    match ext {
        Some(e) => format!("{stem}.{e}"),
        None => stem,
    }
}

/// Copia `src` en `dst` (crea directorios) calculando el SHA-256. Devuelve (bytes, hash hex).
pub fn copy_with_hash(src: &Path, dst: &Path) -> anyhow::Result<(i64, String)> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent).with_context(|| format!("crear {}", parent.display()))?;
    }
    let mut input =
        fs::File::open(src).with_context(|| format!("No se pudo abrir {}", src.display()))?;
    let mut output =
        fs::File::create(dst).with_context(|| format!("No se pudo crear {}", dst.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut total: i64 = 0;
    loop {
        let n = input.read(&mut buf).with_context(|| format!("leer {}", src.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        output.write_all(&buf[..n]).with_context(|| format!("escribir {}", dst.display()))?;
        total += n as i64;
    }
    output.flush()?;
    Ok((total, hex::encode(hasher.finalize())))
}

/// SHA-256 hex de unos bytes.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Escribe `bytes` en `dst` de forma atómica (fichero temporal + rename en el mismo directorio).
pub fn write_atomic(dst: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let parent = dst.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    fs::create_dir_all(&parent).with_context(|| format!("crear {}", parent.display()))?;
    let tmp = parent.join(format!(
        ".{}.{}.tmp",
        dst.file_name().and_then(|n| n.to_str()).unwrap_or("f"),
        crate::util::new_id()
    ));
    let res = (|| -> anyhow::Result<()> {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.flush()?;
        drop(f);
        fs::rename(&tmp, dst)?;
        Ok(())
    })();
    if res.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    res.with_context(|| format!("No se pudo escribir {}", dst.display()))
}

/// Tamaño total (bytes) de un fichero o directorio (recursivo). 0 si no existe.
pub fn path_size(path: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else { return 0 };
    if meta.is_file() {
        return meta.len();
    }
    if !meta.is_dir() {
        return 0;
    }
    let mut total = 0u64;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            let Ok(m) = e.metadata() else { continue };
            if m.is_dir() {
                stack.push(e.path());
            } else if m.is_file() {
                total += m.len();
            }
        }
    }
    total
}

/// Borra un directorio y su contenido; ignora que no exista.
pub fn remove_dir_quiet(path: &Path) {
    match fs::remove_dir_all(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => log::warn!("no se pudo borrar {}: {e}", path.display()),
    }
}

/// Ruta absoluta como String (para devolver a Dart).
pub fn path_string(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_names() {
        assert_eq!(sanitize_file_name("../../etc/passwd", "img", &["jpg"]), "passwd.jpg");
        assert_eq!(sanitize_file_name("Foto 1.JPEG", "img", &["jpg", "jpeg"]), "Foto 1.JPEG");
        assert_eq!(sanitize_file_name("  ", "Imagen", &["png"]), "Imagen.png");
        assert_eq!(sanitize_file_name("a:b*c?.pdf", "doc", &["pdf"]), "a_b_c_.pdf");
        assert_eq!(sanitize_file_name("notas.txt", "doc", &["pdf"]), "notas.txt.pdf");
        assert_eq!(sanitize_file_name("C:\\Users\\x\\scan.png", "x", &["png"]), "scan.png");
        let long = "a".repeat(300) + ".pdf";
        let s = sanitize_file_name(&long, "doc", &["pdf"]);
        assert_eq!(s.chars().count(), 100);
        assert!(s.ends_with(".pdf"));
    }

    #[test]
    fn copies_with_hash_and_sizes() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("a.bin");
        fs::write(&src, b"hola").unwrap();
        let dst = d.path().join("x/y/b.bin");
        let (n, h) = copy_with_hash(&src, &dst).unwrap();
        assert_eq!(n, 4);
        assert_eq!(h, sha256_hex(b"hola"));
        assert_eq!(path_size(d.path()), 8);
        write_atomic(&d.path().join("z.bin"), b"123").unwrap();
        assert_eq!(fs::read(d.path().join("z.bin")).unwrap(), b"123");
        remove_dir_quiet(&d.path().join("x"));
        remove_dir_quiet(&d.path().join("no-existe"));
        assert_eq!(path_size(d.path()), 7);
    }
}
