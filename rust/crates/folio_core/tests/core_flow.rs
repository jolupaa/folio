//! Integración del núcleo: persistencia tras reabrir, ámbitos de búsqueda, papelera, adjuntos,
//! OCR guardado, PDF y pizarras.

use folio_core::model::*;
use folio_core::{Core, Paths};

fn open(dir: &std::path::Path) -> Core {
    Core::open(Paths::new(dir.join("data"), dir.join("cache"))).unwrap()
}

fn para(id: &str, text: &str) -> String {
    serde_json::json!([{"id": id, "type": "paragraph", "text": text}]).to_string()
}

fn write_note(core: &Core, folder: Option<&str>, title: &str, text: &str) -> String {
    let n = core.create_note(folder, NoteKind::Text, title).unwrap();
    core.save_note(&n.id, title, &para("b1", text), n.revision).unwrap();
    n.id
}

fn hits(core: &Core, q: &str, scope: SearchScope) -> Vec<String> {
    core.search(q, &scope, 50).unwrap().hits.into_iter().map(|h| h.note_id).collect()
}

fn dirty(core: &Core, note: &str) -> i64 {
    core.db.read().query_row("SELECT dirty FROM index_state WHERE note_id = ?1", [note], |r| r.get(0)).unwrap()
}

fn clear_dirty(core: &Core) {
    core.db.write().execute("UPDATE index_state SET dirty = 0", []).unwrap();
}

fn png(path: &std::path::Path, w: u32, h: u32) {
    image::RgbImage::from_pixel(w, h, image::Rgb([240, 240, 240])).save(path).unwrap();
}

/// PDF mínimo válido: una página por texto; texto vacío = página sin capa de texto.
fn pdf(pages: &[&str]) -> Vec<u8> {
    let mut objs: Vec<String> = Vec::new();
    let n = pages.len();
    let kids: Vec<String> = (0..n).map(|i| format!("{} 0 R", 4 + i * 2)).collect();
    objs.push("<< /Type /Catalog /Pages 2 0 R >>".into());
    objs.push(format!("<< /Type /Pages /Kids [{}] /Count {n} >>", kids.join(" ")));
    objs.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".into());
    for (i, text) in pages.iter().enumerate() {
        let content = if text.is_empty() { String::new() } else { format!("BT /F1 18 Tf 72 720 Td ({text}) Tj ET") };
        objs.push(format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>",
            5 + i * 2
        ));
        objs.push(format!("<< /Length {} >>\nstream\n{content}\nendstream", content.len()));
    }
    let mut out = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n{o}\nendobj\n", i + 1).as_bytes());
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for off in offsets {
        out.extend_from_slice(format!("{off:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}

#[test]
fn everything_persists_after_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let (folder_id, sub_id, note_id, board_id, att_id, att_path);
    {
        let core = open(dir.path());
        let f = core.create_folder(None, "Física").unwrap();
        let s = core.create_folder(Some(&f.id), "Tema 1").unwrap();
        note_id = write_note(&core, Some(&s.id), "Cinemática", "La velocidad es el cambio de posición.");
        core.set_note_pinned(&note_id, true).unwrap();
        let img = dir.path().join("foto.png");
        png(&img, 64, 48);
        let a = core.import_image(&note_id, img.to_str().unwrap(), "foto.png").unwrap();
        let n = core.get_note(&note_id).unwrap();
        let body = serde_json::json!([
            {"id": "b1", "type": "paragraph", "text": "La velocidad es el cambio de posición."},
            {"id": "b2", "type": "image", "attachment_id": a.id}
        ]);
        core.save_note(&note_id, "Cinemática", &body.to_string(), n.revision).unwrap();
        let b = core.create_note(Some(&f.id), NoteKind::Board, "Esquema").unwrap();
        core.save_board(&b.id, "Esquema", r##"{"version":1,"viewport":{"x":5,"y":6,"scale":2.0},"elements":[{"id":"t","type":"text","x":0,"y":0,"w":100,"text":"Fuerzas","color":"#000000FF","size":20}]}"##).unwrap();
        (folder_id, sub_id, board_id, att_id, att_path) = (f.id, s.id, b.id, a.id, a.path);
    }
    // «Reinicio»: nueva instancia sobre los mismos ficheros, con mantenimiento de arranque.
    let core = open(dir.path());
    let report = core.startup_maintenance();
    assert_eq!(report.orphan_attachments_removed, 0, "los adjuntos referenciados no son huérfanos");
    let folders = core.list_folders().unwrap();
    assert_eq!(folders.len(), 2);
    assert_eq!(folders.iter().find(|f| f.id == folder_id).unwrap().total_note_count, 2);
    assert_eq!(core.folder_path(Some(&sub_id)).unwrap().iter().map(|f| f.name.as_str()).collect::<Vec<_>>(), ["Física", "Tema 1"]);
    let note = core.get_note(&note_id).unwrap();
    assert!(note.pinned && note.body_json.contains("b2") && note.revision >= 2);
    assert_eq!(note.attachments.len(), 1);
    assert_eq!(note.attachments[0].id, att_id);
    assert!(std::path::Path::new(&att_path).exists(), "el fichero adjunto sigue en disco");
    assert_eq!((note.attachments[0].width, note.attachments[0].height), (Some(64), Some(48)));
    let board = core.get_board(&board_id).unwrap();
    assert!(board.scene_json.contains("Fuerzas") && board.scene_json.contains("2.0"));
    assert_eq!(hits(&core, "veloc", SearchScope::Library), vec![note_id.clone()]);
    assert_eq!(hits(&core, "fuerzas", SearchScope::Library), vec![board_id]);
    assert_eq!(core.list_notes(NoteListScope::Pinned, None).unwrap().len(), 1);
}

#[test]
fn search_scope_and_index_follow_edit_move_trash_restore() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(dir.path());
    let fis = core.create_folder(None, "Física").unwrap();
    let sub = core.create_folder(Some(&fis.id), "Tema 1").unwrap();
    let qui = core.create_folder(None, "Química").unwrap();
    let a = write_note(&core, Some(&sub.id), "Energía", "La energía cinética depende de la masa.");
    let b = write_note(&core, Some(&qui.id), "Reacciones", "La energía de activación inicia la reacción.");
    let inbox = write_note(&core, None, "Suelta", "Energía solar.");

    assert_eq!(hits(&core, "energia", SearchScope::Library).len(), 3, "sin tildes");
    assert_eq!(hits(&core, "energía cin", SearchScope::Folder(fis.id.clone())), vec![a.clone()], "carpeta recursiva + prefijo");
    assert_eq!(hits(&core, "energia", SearchScope::Folder(qui.id.clone())), vec![b.clone()]);
    assert_eq!(hits(&core, "energia", SearchScope::Note(inbox.clone())), vec![inbox.clone()]);
    assert!(hits(&core, "activación", SearchScope::Note(a.clone())).is_empty());

    // Editar: el texto antiguo deja de encontrarse y la nota queda marcada para la IA.
    clear_dirty(&core);
    let n = core.get_note(&a).unwrap();
    core.save_note(&a, "Energía", &para("b1", "El trabajo es fuerza por desplazamiento."), n.revision).unwrap();
    assert!(hits(&core, "cinética", SearchScope::Library).is_empty());
    assert_eq!(hits(&core, "desplazamiento", SearchScope::Folder(fis.id.clone())), vec![a.clone()]);
    assert_eq!(dirty(&core, &a), 1);
    let stale = core.save_note(&a, "Energía", &para("b1", "El trabajo es fuerza por desplazamiento."), n.revision).unwrap();
    assert!(stale.conflict, "revisión base antigua → conflicto señalado");

    // Mover cambia el ámbito.
    core.move_note(&b, Some(&sub.id)).unwrap();
    assert_eq!(hits(&core, "activacion", SearchScope::Folder(fis.id.clone())), vec![b.clone()]);
    assert!(hits(&core, "activacion", SearchScope::Folder(qui.id.clone())).is_empty());

    // Papelera de carpeta: arrastra subcarpetas y notas; restaurar lo devuelve todo.
    let n = core.trash_folder(&fis.id).unwrap();
    assert_eq!(n, 2);
    assert!(hits(&core, "desplazamiento", SearchScope::Library).is_empty());
    let trash = core.list_trash().unwrap();
    assert_eq!(trash.len(), 1, "solo la carpeta de nivel superior: {trash:?}");
    assert_eq!((trash[0].kind, trash[0].contained_notes, trash[0].days_left), (TrashKind::Folder, 2, 30));
    clear_dirty(&core);
    core.restore_from_trash(TrashKind::Folder, &fis.id).unwrap();
    assert_eq!(hits(&core, "desplazamiento", SearchScope::Folder(fis.id.clone())), vec![a.clone()]);
    assert_eq!(core.list_folders().unwrap().len(), 3);

    // Nota en papelera cuya carpeta se borra después: restaurarla restaura la carpeta.
    core.trash_note(&a).unwrap();
    core.trash_folder(&fis.id).unwrap();
    core.restore_from_trash(TrashKind::Note, &a).unwrap();
    assert_eq!(core.get_note(&a).unwrap().folder_id.as_deref(), Some(sub.id.as_str()));
    assert!(core.list_folders().unwrap().iter().any(|f| f.id == sub.id), "se restauran los ancestros");

    // Borrado definitivo y purga por antigüedad.
    core.trash_note(&inbox).unwrap();
    core.delete_permanently(TrashKind::Note, &inbox).unwrap();
    assert!(core.get_note(&inbox).is_err());
    core.trash_note(&a).unwrap();
    assert_eq!(core.purge_expired_trash(folio_core::util::now_ms() + 31 * DAY_MS).unwrap() >= 1, true);
    assert!(core.get_note(&a).is_err());
    let counts = core.library_counts().unwrap();
    assert_eq!(counts.all as usize, core.list_notes(NoteListScope::All, None).unwrap().len());
}

#[test]
fn folders_reject_cycles_and_empty_names() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(dir.path());
    let a = core.create_folder(None, "A").unwrap();
    let b = core.create_folder(Some(&a.id), "B").unwrap();
    let c = core.create_folder(Some(&b.id), "C").unwrap();
    assert!(core.move_folder(&a.id, Some(&c.id)).is_err(), "ciclo");
    assert!(core.move_folder(&a.id, Some(&a.id)).is_err());
    assert!(core.create_folder(None, "   ").is_err());
    assert!(core.rename_folder(&a.id, "").is_err());
    core.move_folder(&c.id, None).unwrap();
    assert_eq!(core.folder_path(Some(&c.id)).unwrap().len(), 1);
    assert!(core.move_note("no-existe", Some(&a.id)).is_err());
}

#[test]
fn scan_note_keeps_text_image_link_and_is_searchable() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(dir.path());
    let img = dir.path().join("pagina.png");
    png(&img, 200, 300);
    let page = |text: &str, edited: bool| OcrPageInput {
        image_path: Some(img.to_str().unwrap().to_string()),
        text: text.to_string(),
        engine: "mlkit_latin".into(),
        confidence: Some(0.9),
        lines: vec![OcrLine { text: text.to_string(), x: 0.1, y: 0.1, w: 0.8, h: 0.05, confidence: Some(0.9) }],
        edited,
    };
    let note = core.create_note_from_scan(None, "", &[page("Teorema de Pitágoras", false), page("Hipotenusa al cuadrado", true)]).unwrap();
    assert!(note.title.starts_with("Apuntes escaneados"));
    assert_eq!(note.attachments.len(), 2);
    let pages = core.list_attachment_pages(&note.attachments[1].id).unwrap();
    assert_eq!(pages[0].text_source, TextSource::OcrEdited);
    assert!(pages[0].materialized && pages[0].lines.len() == 1);
    assert!(std::path::Path::new(pages[0].image_path.as_ref().unwrap()).exists());
    assert!(note.body_json.contains(&pages[0].id), "bloques enlazados a su página");
    assert_eq!(hits(&core, "pitagoras", SearchScope::Library), vec![note.id.clone()]);
    assert_eq!(core.search("hipotenusa", &SearchScope::Library, 10).unwrap().hits.len(), 1, "el texto materializado no se indexa dos veces");

    let more = core.append_scan_to_note(&note.id, &[page("Catetos", false)]).unwrap();
    assert_eq!(more.attachments.len(), 3);
    assert_eq!(hits(&core, "catetos", SearchScope::Note(note.id.clone())), vec![note.id.clone()]);

    // Quitar el bloque de imagen y reiniciar: el adjunto sin referencias se recoge.
    let blocks: Vec<serde_json::Value> = serde_json::from_str(&more.body_json).unwrap();
    let first_att = more.attachments[0].id.clone();
    let kept: Vec<_> = blocks
        .into_iter()
        .filter(|b| b["attachment_id"] != first_att.as_str() && !b["source_page_id"].is_string() || b["attachment_id"].is_string() && b["attachment_id"] != first_att.as_str())
        .collect();
    core.save_note(&note.id, &more.title, &serde_json::to_string(&kept).unwrap(), more.revision).unwrap();
    let removed = core.collect_orphan_attachments().unwrap();
    assert!(removed >= 1);
    assert!(!std::path::Path::new(&more.attachments[0].path).exists());
}

#[test]
fn pdf_text_layer_is_extracted_and_scanned_pages_flagged() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(dir.path());
    let note = core.create_note(None, NoteKind::Text, "Apuntes PDF").unwrap();
    let path = dir.path().join("tema.pdf");
    std::fs::write(&path, pdf(&["Termodinamica: primera ley y entropia del sistema", ""])).unwrap();
    let r = core.import_pdf(&note.id, path.to_str().unwrap(), "tema.pdf").unwrap();
    assert_eq!(r.attachment.page_count, 2);
    assert_eq!(r.pages_needing_ocr, vec![1], "la página sin capa de texto necesita OCR");
    assert_eq!(r.pages[0].text_source, TextSource::PdfText);
    assert!(r.pages[0].text.contains("entropia"));
    let h = core.search("entropia", &SearchScope::Note(note.id.clone()), 10).unwrap().hits;
    assert_eq!((h[0].matched_in, h[0].page_index, h[0].attachment_name.as_deref()), (MatchField::Attachment, Some(0), Some("tema.pdf")));

    // OCR de la página escaneada y corrección manual posterior.
    let p = core
        .set_page_ocr(&r.pages[1].id, &OcrPageInput { image_path: None, text: "Ciclo de Carnot".into(), engine: "apple_vision".into(), confidence: Some(0.7), lines: vec![], edited: false })
        .unwrap();
    assert_eq!(p.text_source, TextSource::Ocr);
    assert_eq!(core.search("carnot", &SearchScope::Library, 10).unwrap().hits[0].page_index, Some(1));
    let p = core.update_page_text(&p.id, "Ciclo de Carnot ideal").unwrap();
    assert_eq!(p.text_source, TextSource::OcrEdited);
    assert_eq!(dirty(&core, &note.id), 1);

    // Un fichero que no es PDF se rechaza sin dejar restos.
    let bad = dir.path().join("falso.pdf");
    std::fs::write(&bad, b"esto no es un pdf").unwrap();
    assert!(core.import_pdf(&note.id, bad.to_str().unwrap(), "falso.pdf").is_err());
    assert_eq!(core.get_note(&note.id).unwrap().attachments.len(), 1);

    core.delete_attachment(&r.attachment.id).unwrap();
    assert!(core.search("entropia", &SearchScope::Library, 10).unwrap().hits.is_empty());
    assert!(!std::path::Path::new(&r.attachment.path).exists());
}

/// Regresión: guardar mientras otra conexión (el indexador de IA) escribe sin parar no debe dar
/// «database is locked» (las transacciones de escritura son IMMEDIATE y esperan su turno).
#[test]
fn saving_while_another_connection_writes_never_reports_locked() {
    let dir = tempfile::tempdir().unwrap();
    let core = open(dir.path());
    let id = write_note(&core, None, "Concurrente", "inicio");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let conn = core.db.connect().unwrap();
    let stop2 = stop.clone();
    let writer = std::thread::spawn(move || {
        let mut i = 0u64;
        while !stop2.load(std::sync::atomic::Ordering::SeqCst) {
            conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('k', ?1)", [i.to_string()]).unwrap();
            i += 1;
        }
        i
    });
    for i in 0..300 {
        let n = core.get_note(&id).unwrap();
        core.save_note(&id, "Concurrente", &para("b1", &format!("versión {i}")), n.revision).unwrap();
        if i % 50 == 0 {
            let f = core.create_folder(None, &format!("C{i}")).unwrap();
            core.move_note(&id, Some(&f.id)).unwrap();
        }
    }
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    assert!(writer.join().unwrap() > 0);
    assert_eq!(hits(&core, "versión 299", SearchScope::Library), vec![id]);
}
