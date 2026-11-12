//! Adjuntos (imágenes y PDFs) y sus páginas: importación, OCR, corrección de texto, borrado y
//! notas creadas a partir de escaneos.
//!
//! Ficheros: `files/<attachment_id>/<nombre>` y `files/<attachment_id>/pages/<n>.jpg`.
//! En BD las rutas son relativas a `files/`; hacia fuera se devuelven absolutas.
//! Los ficheros se copian ANTES de abrir la transacción; si la transacción falla se borran.

use crate::blocks::{self, Block, BlockType};
use crate::folders::ensure_folder_usable;
use crate::fsutil::{copy_with_hash, path_string, remove_dir_quiet, sanitize_file_name};
use crate::images;
use crate::model::{
    Attachment, AttachmentKind, AttachmentPage, Note, NoteKind, OcrLine, OcrPageInput, PdfImportResult,
    TextSource,
};
use crate::notes::{active_note_meta, load_note, MAX_TITLE_CHARS};
use crate::pdf;
use crate::search_index;
use crate::util::{new_id, now_ms, short_date_es, single_line};
use crate::Core;
use anyhow::{anyhow, bail, Context};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};

const ATT_COLS: &str =
    "id, note_id, kind, file_name, mime, rel_path, size_bytes, width, height, page_count, created_at";
const PAGE_COLS: &str = "id, attachment_id, page_index, image_rel_path, text, text_source, ocr_engine, \
                         ocr_confidence, ocr_layout, materialized";

fn attachment_from_row(r: &rusqlite::Row<'_>, files: &Path) -> rusqlite::Result<Attachment> {
    let rel: String = r.get(5)?;
    Ok(Attachment {
        id: r.get(0)?,
        note_id: r.get(1)?,
        kind: AttachmentKind::from_db(&r.get::<_, String>(2)?),
        file_name: r.get(3)?,
        mime: r.get(4)?,
        path: path_string(&files.join(rel)),
        size_bytes: r.get(6)?,
        width: r.get(7)?,
        height: r.get(8)?,
        page_count: r.get(9)?,
        created_at: r.get(10)?,
    })
}

fn page_from_row(r: &rusqlite::Row<'_>, files: &Path) -> rusqlite::Result<AttachmentPage> {
    let image_rel: Option<String> = r.get(3)?;
    let layout: Option<String> = r.get(8)?;
    let lines = layout
        .as_deref()
        .and_then(|j| serde_json::from_str::<Vec<OcrLine>>(j).ok())
        .unwrap_or_default();
    Ok(AttachmentPage {
        id: r.get(0)?,
        attachment_id: r.get(1)?,
        page_index: r.get(2)?,
        image_path: image_rel.map(|rel| path_string(&files.join(rel))),
        text: r.get(4)?,
        text_source: TextSource::from_db(&r.get::<_, String>(5)?),
        ocr_engine: r.get(6)?,
        ocr_confidence: r.get(7)?,
        lines,
        materialized: r.get::<_, i64>(9)? != 0,
    })
}

/// Adjuntos de una nota en orden de creación.
pub(crate) fn attachments_of(conn: &Connection, files: &Path, note_id: &str) -> anyhow::Result<Vec<Attachment>> {
    let mut s = conn.prepare_cached(&format!(
        "SELECT {ATT_COLS} FROM attachments WHERE note_id = ?1 ORDER BY created_at, rowid"
    ))?;
    let v = s
        .query_map(params![note_id], |r| attachment_from_row(r, files))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(v)
}

fn load_attachment(conn: &Connection, files: &Path, id: &str) -> anyhow::Result<Attachment> {
    conn.prepare_cached(&format!("SELECT {ATT_COLS} FROM attachments WHERE id = ?1"))?
        .query_row(params![id], |r| attachment_from_row(r, files))
        .optional()?
        .ok_or_else(|| anyhow!("El adjunto no existe"))
}

fn load_page(conn: &Connection, files: &Path, page_id: &str) -> anyhow::Result<AttachmentPage> {
    conn.prepare_cached(&format!("SELECT {PAGE_COLS} FROM attachment_pages WHERE id = ?1"))?
        .query_row(params![page_id], |r| page_from_row(r, files))
        .optional()?
        .ok_or_else(|| anyhow!("La página no existe"))
}

fn load_pages(conn: &Connection, files: &Path, attachment_id: &str) -> anyhow::Result<Vec<AttachmentPage>> {
    let mut s = conn.prepare_cached(&format!(
        "SELECT {PAGE_COLS} FROM attachment_pages WHERE attachment_id = ?1 ORDER BY page_index"
    ))?;
    let v = s
        .query_map(params![attachment_id], |r| page_from_row(r, files))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(v)
}

/// Texto de OCR normalizado: saltos `\n`, sin espacios finales por línea, recortado.
fn normalize_ocr_text(text: &str) -> String {
    let t = text.replace("\r\n", "\n").replace('\r', "\n");
    let lines: Vec<&str> = t.split('\n').map(str::trim_end).collect();
    lines.join("\n").trim().to_string()
}

fn sanitize_lines(lines: &[OcrLine]) -> Vec<OcrLine> {
    let fin = |v: f64| if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
    lines
        .iter()
        .map(|l| OcrLine {
            text: l.text.clone(),
            x: fin(l.x),
            y: fin(l.y),
            w: fin(l.w),
            h: fin(l.h),
            confidence: l.confidence.filter(|c| c.is_finite()).map(|c| c.clamp(0.0, 1.0)),
        })
        .collect()
}

fn layout_json(lines: &[OcrLine]) -> Option<String> {
    if lines.is_empty() {
        return None;
    }
    serde_json::to_string(&sanitize_lines(lines)).ok()
}

fn ocr_source(input: &OcrPageInput) -> TextSource {
    if input.edited {
        TextSource::OcrEdited
    } else {
        TextSource::Ocr
    }
}

fn opt_engine(engine: &str) -> Option<String> {
    let e = engine.trim();
    (!e.is_empty()).then(|| e.to_string())
}

/// Fichero de página escaneada preparado en disco (antes de la transacción).
struct PreparedScanPage {
    attachment_id: String,
    page_id: String,
    file_name: String,
    mime: &'static str,
    rel_path: String,
    size: i64,
    sha: String,
    width: Option<u32>,
    height: Option<u32>,
    text: String,
    source: TextSource,
    engine: Option<String>,
    confidence: Option<f64>,
    layout: Option<String>,
}

/// Borra los directorios de adjuntos si una operación falla tras copiar ficheros.
struct DirCleanup {
    dirs: Vec<PathBuf>,
    armed: bool,
}

impl DirCleanup {
    fn new() -> Self {
        DirCleanup { dirs: Vec::new(), armed: true }
    }
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for DirCleanup {
    fn drop(&mut self) {
        if self.armed {
            for d in &self.dirs {
                remove_dir_quiet(d);
            }
        }
    }
}

impl Core {
    fn attachment_dir(&self, attachment_id: &str) -> PathBuf {
        self.paths.files_dir().join(attachment_id)
    }

    /// Copia una imagen al almacenamiento de la app y la asocia a la nota (1 página, sin texto).
    pub fn import_image(&self, note_id: &str, source_path: &str, file_name: &str) -> anyhow::Result<Attachment> {
        active_note_meta(&self.db.read(), note_id)?;
        let src = Path::new(source_path);
        if !src.is_file() {
            bail!("No se encuentra la imagen de origen");
        }
        let probed = images::probe(src)?
            .ok_or_else(|| anyhow!("Formato de imagen no compatible (usa JPEG, PNG, WebP, GIF o HEIC)"))?;
        let att_id = new_id();
        let name = sanitize_file_name(file_name, "Imagen", probed.exts);
        let rel = format!("{att_id}/{name}");
        let mut cleanup = DirCleanup::new();
        cleanup.dirs.push(self.attachment_dir(&att_id));
        let (size, sha) = copy_with_hash(src, &self.paths.files_dir().join(&rel))?;
        let now = now_ms();

        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        active_note_meta(&tx, note_id)?;
        tx.execute(
            "INSERT INTO attachments(id, note_id, kind, file_name, mime, rel_path, size_bytes, sha256,
                                     width, height, page_count, created_at)
             VALUES (?1, ?2, 'image', ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1, ?10)",
            params![att_id, note_id, name, probed.mime, rel, size, sha, probed.width, probed.height, now],
        )?;
        tx.execute(
            "INSERT INTO attachment_pages(id, attachment_id, page_index, image_rel_path, text, text_source,
                                          materialized, updated_at)
             VALUES (?1, ?2, 0, ?3, '', 'none', 0, ?4)",
            params![new_id(), att_id, rel, now],
        )?;
        search_index::mark_dirty(&tx, &[note_id])?;
        tx.commit()?;
        cleanup.disarm();
        let att = load_attachment(&conn, &self.paths.files_dir(), &att_id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(att)
    }

    /// Copia un PDF, extrae la capa de texto por página y señala las páginas que necesitan OCR
    /// (< 25 caracteres no blancos).
    pub fn import_pdf(&self, note_id: &str, source_path: &str, file_name: &str) -> anyhow::Result<PdfImportResult> {
        active_note_meta(&self.db.read(), note_id)?;
        let src = Path::new(source_path);
        if !src.is_file() {
            bail!("No se encuentra el PDF de origen");
        }
        let att_id = new_id();
        let name = sanitize_file_name(file_name, "Documento", &["pdf"]);
        let rel = format!("{att_id}/{name}");
        let mut cleanup = DirCleanup::new();
        cleanup.dirs.push(self.attachment_dir(&att_id));
        let dst = self.paths.files_dir().join(&rel);
        let (size, sha) = copy_with_hash(src, &dst)?;
        let bytes = std::fs::read(&dst).with_context(|| format!("leer {}", dst.display()))?;
        let extracted = pdf::extract(&bytes)?;
        drop(bytes);
        let page_count = extracted.page_count();
        let now = now_ms();

        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        active_note_meta(&tx, note_id)?;
        tx.execute(
            "INSERT INTO attachments(id, note_id, kind, file_name, mime, rel_path, size_bytes, sha256,
                                     width, height, page_count, created_at)
             VALUES (?1, ?2, 'pdf', ?3, 'application/pdf', ?4, ?5, ?6, NULL, NULL, ?7, ?8)",
            params![att_id, note_id, name, rel, size, sha, page_count, now],
        )?;
        let mut pages_needing_ocr = Vec::new();
        {
            let mut ins = tx.prepare_cached(
                "INSERT INTO attachment_pages(id, attachment_id, page_index, image_rel_path, text, text_source,
                                              materialized, updated_at)
                 VALUES (?1, ?2, ?3, NULL, ?4, ?5, 0, ?6)",
            )?;
            for (i, text) in extracted.pages.iter().enumerate() {
                let page_id = new_id();
                let source = if text.trim().is_empty() { TextSource::None } else { TextSource::PdfText };
                ins.execute(params![page_id, att_id, i as u32, text, source.as_str(), now])?;
                if pdf::needs_ocr(text) {
                    pages_needing_ocr.push(i as u32);
                }
                search_index::sync_page_doc(&tx, &page_id)?;
            }
        }
        search_index::mark_dirty(&tx, &[note_id])?;
        tx.commit()?;
        cleanup.disarm();
        let files = self.paths.files_dir();
        let attachment = load_attachment(&conn, &files, &att_id)?;
        let pages = load_pages(&conn, &files, &att_id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(PdfImportResult { attachment, pages, pages_needing_ocr })
    }

    pub fn get_attachment(&self, id: &str) -> anyhow::Result<Attachment> {
        load_attachment(&self.db.read(), &self.paths.files_dir(), id)
    }

    pub fn list_attachment_pages(&self, attachment_id: &str) -> anyhow::Result<Vec<AttachmentPage>> {
        let conn = self.db.read();
        let files = self.paths.files_dir();
        load_attachment(&conn, &files, attachment_id)?;
        load_pages(&conn, &files, attachment_id)
    }

    pub fn get_page(&self, page_id: &str) -> anyhow::Result<AttachmentPage> {
        load_page(&self.db.read(), &self.paths.files_dir(), page_id)
    }

    /// Guarda el resultado de OCR de una página existente. Si trae imagen, se copia a
    /// `files/<adjunto>/pages/<n>.jpg` (recodificada a JPEG si hace falta).
    pub fn set_page_ocr(&self, page_id: &str, input: &OcrPageInput) -> anyhow::Result<AttachmentPage> {
        let files = self.paths.files_dir();
        let (att_id, page_index, note_id): (String, u32, String) = self
            .db
            .read()
            .query_row(
                "SELECT p.attachment_id, p.page_index, a.note_id FROM attachment_pages p
                 JOIN attachments a ON a.id = p.attachment_id WHERE p.id = ?1",
                params![page_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .ok_or_else(|| anyhow!("La página no existe"))?;

        let mut image_rel: Option<String> = None;
        if let Some(src) = input.image_path.as_deref().filter(|p| !p.trim().is_empty()) {
            let src = Path::new(src);
            if !src.is_file() {
                bail!("No se encuentra la imagen de la página");
            }
            let rel = format!("{att_id}/pages/{page_index}.jpg");
            let dst = files.join(&rel);
            let same = std::fs::canonicalize(src).ok() == std::fs::canonicalize(&dst).ok() && dst.exists();
            if !same {
                images::store_as_jpeg(src, &dst)?;
            }
            image_rel = Some(rel);
        }
        let text = normalize_ocr_text(&input.text);
        let source = ocr_source(input);
        let confidence = input.confidence.filter(|c| c.is_finite()).map(|c| c.clamp(0.0, 1.0));

        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let n = tx.execute(
            "UPDATE attachment_pages
             SET image_rel_path = COALESCE(?2, image_rel_path), text = ?3, text_source = ?4,
                 ocr_engine = ?5, ocr_confidence = ?6, ocr_layout = ?7, updated_at = ?8
             WHERE id = ?1",
            params![
                page_id,
                image_rel,
                text,
                source.as_str(),
                opt_engine(&input.engine),
                confidence,
                layout_json(&input.lines),
                now_ms()
            ],
        )?;
        if n == 0 {
            bail!("La página no existe");
        }
        search_index::sync_page_doc(&tx, page_id)?;
        search_index::mark_dirty(&tx, &[&note_id])?;
        tx.commit()?;
        let page = load_page(&conn, &files, page_id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(page)
    }

    /// Corrección manual del texto de una página: `OcrEdited` (o `PdfText` si lo era).
    pub fn update_page_text(&self, page_id: &str, text: &str) -> anyhow::Result<AttachmentPage> {
        let text = normalize_ocr_text(text);
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let (source, note_id): (String, String) = tx
            .query_row(
                "SELECT p.text_source, a.note_id FROM attachment_pages p
                 JOIN attachments a ON a.id = p.attachment_id WHERE p.id = ?1",
                params![page_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
            .ok_or_else(|| anyhow!("La página no existe"))?;
        let new_source = match TextSource::from_db(&source) {
            TextSource::PdfText => TextSource::PdfText,
            TextSource::None if text.is_empty() => TextSource::None,
            _ => TextSource::OcrEdited,
        };
        tx.execute(
            "UPDATE attachment_pages SET text = ?2, text_source = ?3, updated_at = ?4 WHERE id = ?1",
            params![page_id, text, new_source.as_str(), now_ms()],
        )?;
        search_index::sync_page_doc(&tx, page_id)?;
        search_index::mark_dirty(&tx, &[&note_id])?;
        tx.commit()?;
        let page = load_page(&conn, &self.paths.files_dir(), page_id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(page)
    }

    /// Borra el adjunto (fila, páginas, índices y ficheros). No modifica el cuerpo de la nota:
    /// la UI quita el bloque.
    pub fn delete_attachment(&self, id: &str) -> anyhow::Result<()> {
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let note_id: String = tx
            .query_row("SELECT note_id FROM attachments WHERE id = ?1", params![id], |r| r.get(0))
            .optional()?
            .ok_or_else(|| anyhow!("El adjunto no existe"))?;
        tx.execute("DELETE FROM attachments WHERE id = ?1", params![id])?;
        search_index::mark_dirty(&tx, &[&note_id])?;
        tx.commit()?;
        drop(conn);
        remove_dir_quiet(&self.attachment_dir(id));
        self.db.signal().bump();
        Ok(())
    }

    /// Copia las imágenes de las páginas escaneadas a `files/` (fuera de la transacción).
    fn prepare_scan_pages(
        &self,
        pages: &[OcrPageInput],
        first_number: usize,
        cleanup: &mut DirCleanup,
    ) -> anyhow::Result<Vec<PreparedScanPage>> {
        if pages.is_empty() {
            bail!("No hay páginas escaneadas");
        }
        let mut out = Vec::with_capacity(pages.len());
        for (i, p) in pages.iter().enumerate() {
            let src = p
                .image_path
                .as_deref()
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| anyhow!("Falta la imagen de la página {}", i + 1))?;
            let src = Path::new(src);
            if !src.is_file() {
                bail!("No se encuentra la imagen de la página {}", i + 1);
            }
            let probed = images::probe(src)?
                .ok_or_else(|| anyhow!("La imagen de la página {} no es compatible", i + 1))?;
            let att_id = new_id();
            let file_name = sanitize_file_name(
                &format!("Escaneo {}", first_number + i),
                "Escaneo",
                probed.exts,
            );
            let rel = format!("{att_id}/{file_name}");
            cleanup.dirs.push(self.attachment_dir(&att_id));
            let (size, sha) = copy_with_hash(src, &self.paths.files_dir().join(&rel))?;
            let text = normalize_ocr_text(&p.text);
            out.push(PreparedScanPage {
                attachment_id: att_id,
                page_id: new_id(),
                file_name,
                mime: probed.mime,
                rel_path: rel,
                size,
                sha,
                width: probed.width,
                height: probed.height,
                source: ocr_source(p),
                engine: opt_engine(&p.engine),
                confidence: p.confidence.filter(|c| c.is_finite()).map(|c| c.clamp(0.0, 1.0)),
                layout: layout_json(&p.lines),
                text,
            });
        }
        Ok(out)
    }

    /// Inserta adjuntos + páginas materializadas y devuelve los bloques (imagen + texto OCR).
    fn insert_scan_pages(&self, tx: &Connection, note_id: &str, pages: &[PreparedScanPage]) -> anyhow::Result<Vec<Block>> {
        let now = now_ms();
        let mut blocks_out = Vec::new();
        let mut ins_att = tx.prepare_cached(
            "INSERT INTO attachments(id, note_id, kind, file_name, mime, rel_path, size_bytes, sha256,
                                     width, height, page_count, created_at)
             VALUES (?1, ?2, 'image', ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1, ?10)",
        )?;
        let mut ins_page = tx.prepare_cached(
            "INSERT INTO attachment_pages(id, attachment_id, page_index, image_rel_path, text, text_source,
                                          ocr_engine, ocr_confidence, ocr_layout, materialized, updated_at)
             VALUES (?1, ?2, 0, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9)",
        )?;
        for (i, p) in pages.iter().enumerate() {
            // created_at creciente para conservar el orden de las páginas.
            ins_att.execute(params![
                p.attachment_id,
                note_id,
                p.file_name,
                p.mime,
                p.rel_path,
                p.size,
                p.sha,
                p.width,
                p.height,
                now + i as i64
            ])?;
            ins_page.execute(params![
                p.page_id,
                p.attachment_id,
                p.rel_path,
                p.text,
                p.source.as_str(),
                p.engine,
                p.confidence,
                p.layout,
                now
            ])?;
            let mut img = Block::new(BlockType::Image, "");
            img.attachment_id = Some(p.attachment_id.clone());
            blocks_out.push(img);
            blocks_out.extend(blocks::blocks_from_ocr_text(&p.text, Some(&p.page_id)));
        }
        Ok(blocks_out)
    }

    /// Crea una nota con las páginas escaneadas: por página, bloque de imagen + párrafos del
    /// texto con `source_page_id`. Páginas `materialized = true`. Título vacío →
    /// «Apuntes escaneados <fecha>».
    pub fn create_note_from_scan(&self, folder_id: Option<&str>, title: &str, pages: &[OcrPageInput]) -> anyhow::Result<Note> {
        ensure_folder_usable(&self.db.read(), folder_id)?;
        let mut cleanup = DirCleanup::new();
        let prepared = self.prepare_scan_pages(pages, 1, &mut cleanup)?;
        let now = now_ms();
        let title = match single_line(title, MAX_TITLE_CHARS) {
            t if t.is_empty() => format!("Apuntes escaneados {}", short_date_es(now)),
            t => t,
        };
        let id = new_id();
        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_folder_usable(&tx, folder_id)?;
        tx.execute(
            "INSERT INTO notes(id, folder_id, kind, title, body, plain_text, pinned, created_at, updated_at, revision)
             VALUES (?1, ?2, 'text', ?3, '[]', '', 0, ?4, ?4, 0)",
            params![id, folder_id, title, now],
        )?;
        let new_blocks = self.insert_scan_pages(&tx, &id, &prepared)?;
        tx.execute(
            "UPDATE notes SET body = ?2, plain_text = ?3 WHERE id = ?1",
            params![id, blocks::to_json(&new_blocks), blocks::to_plain_text(&new_blocks)],
        )?;
        search_index::sync_note_doc(&tx, &id)?;
        search_index::mark_dirty(&tx, &[&id])?;
        tx.commit()?;
        cleanup.disarm();
        let note = load_note(self, &conn, &id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(note)
    }

    /// Añade las páginas escaneadas al final de una nota de texto existente (revisión +1).
    /// Conserva intactos los bloques existentes (incluidos campos desconocidos).
    pub fn append_scan_to_note(&self, note_id: &str, pages: &[OcrPageInput]) -> anyhow::Result<Note> {
        let meta = active_note_meta(&self.db.read(), note_id)?;
        if meta.kind != NoteKind::Text {
            bail!("Solo se pueden añadir escaneos a notas de texto");
        }
        let existing_images: usize = self.db.read().query_row(
            "SELECT count(*) FROM attachments WHERE note_id = ?1 AND kind = 'image'",
            params![note_id],
            |r| r.get::<_, i64>(0),
        )? as usize;
        let mut cleanup = DirCleanup::new();
        let prepared = self.prepare_scan_pages(pages, existing_images + 1, &mut cleanup)?;

        let mut conn = self.db.write();
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let meta = active_note_meta(&tx, note_id)?;
        if meta.kind != NoteKind::Text {
            bail!("Solo se pueden añadir escaneos a notas de texto");
        }
        let body: String = tx.query_row("SELECT body FROM notes WHERE id = ?1", params![note_id], |r| r.get(0))?;
        let mut values: Vec<serde_json::Value> = if body.trim().is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(&body).map_err(|e| anyhow!("Cuerpo de nota no válido: {e}"))?
        };
        let new_blocks = self.insert_scan_pages(&tx, note_id, &prepared)?;
        for b in &new_blocks {
            values.push(serde_json::to_value(b)?);
        }
        let new_body = serde_json::to_string(&values)?;
        let parsed = blocks::parse(&new_body)?;
        let now = now_ms().max(meta.updated_at);
        tx.execute(
            "UPDATE notes SET body = ?2, plain_text = ?3, updated_at = ?4, revision = revision + 1 WHERE id = ?1",
            params![note_id, new_body, blocks::to_plain_text(&parsed), now],
        )?;
        search_index::sync_note_doc(&tx, note_id)?;
        search_index::mark_dirty(&tx, &[note_id])?;
        tx.commit()?;
        cleanup.disarm();
        let note = load_note(self, &conn, note_id)?;
        drop(conn);
        self.db.signal().bump();
        Ok(note)
    }
}
