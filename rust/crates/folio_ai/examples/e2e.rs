//! Prueba real en el HOST (no es CI ni un móvil): índice + embeddings + preguntas + estudio con
//! llama.cpp y los modelos del catálogo. Uso:
//!   FOLIO_TEST_MODELS_DIR=~/.cache/folio-test-models cargo run --release -p folio_ai --example e2e
//! El directorio debe contener Qwen3.5-2B-Q4_K_M.gguf y Qwen3-Embedding-0.6B-Q8_0.gguf.

use folio_ai::catalog::{QWEN35_2B, QWEN3_EMBEDDING};
use folio_ai::models::ModelManager;
use folio_ai::types::*;
use folio_ai::{store, Ai, AiSink};
use folio_core::model::NoteKind;
use folio_core::{Core, Paths};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

fn body(paragraphs: &[&str]) -> String {
    let blocks: Vec<serde_json::Value> =
        paragraphs.iter().enumerate().map(|(i, t)| serde_json::json!({"id": format!("b{i}"), "type": "paragraph", "text": t})).collect();
    serde_json::to_string(&blocks).unwrap()
}

fn run(label: &str, start: impl FnOnce(AiSink)) -> AiEvent {
    let (tx, rx) = mpsc::channel();
    let tx = Mutex::new(tx);
    let t0 = Instant::now();
    start(Arc::new(move |ev| {
        let _ = tx.lock().unwrap().send(ev);
    }));
    let mut first_token = None;
    let mut tokens = 0usize;
    loop {
        let ev = rx.recv_timeout(Duration::from_secs(900)).expect("evento");
        match ev.kind {
            AiEventKind::Token => {
                first_token.get_or_insert(t0.elapsed());
                tokens += 1;
            }
            AiEventKind::Progress => println!("   · {}", ev.text),
            AiEventKind::Done | AiEventKind::Error | AiEventKind::Cancelled => {
                println!(
                    "== {label}: {:?} en {:.1}s (primer texto a los {:.1}s, {tokens} fragmentos de stream)",
                    ev.kind,
                    t0.elapsed().as_secs_f64(),
                    first_token.unwrap_or_default().as_secs_f64()
                );
                return ev;
            }
            _ => {}
        }
    }
}

fn main() -> anyhow::Result<()> {
    let models_dir = std::env::var("FOLIO_TEST_MODELS_DIR").expect("define FOLIO_TEST_MODELS_DIR");
    let dir = tempfile::tempdir()?;
    let paths = Paths::new(dir.path().join("data"), dir.path().join("cache"));
    let core = Core::open(paths.clone())?;
    let models = ModelManager::new(core.db.clone(), paths.models_dir());
    for id in [QWEN35_2B, QWEN3_EMBEDDING] {
        let spec = models.spec(id)?;
        let src = std::path::Path::new(&models_dir).join(&spec.file_name);
        anyhow::ensure!(src.exists(), "falta {}", src.display());
        std::os::unix::fs::symlink(&src, paths.models_dir().join(&spec.file_name))?;
        core.db.write().execute(
            "INSERT INTO models(id,status,downloaded_bytes,total_bytes,file_rel_path,updated_at) VALUES (?1,'installed',?2,?2,?3,0)",
            rusqlite::params![id, spec.size_bytes, spec.file_name],
        )?;
    }
    let ai = Ai::new(core.db.clone(), paths)?;
    println!("dispositivo: {:?}", ai.device_info());

    let fis = core.create_folder(None, "Física")?;
    let his = core.create_folder(None, "Historia")?;
    let mk = |folder: &str, title: &str, ps: &[&str]| -> anyhow::Result<String> {
        let n = core.create_note(Some(folder), NoteKind::Text, title)?;
        core.save_note(&n.id, title, &body(ps), n.revision)?;
        Ok(n.id)
    };
    mk(&fis.id, "Cinemática", &[
        "La cinemática estudia el movimiento de los cuerpos sin atender a sus causas.",
        "La velocidad media es el desplazamiento dividido entre el tiempo empleado y se mide en metros por segundo (m/s).",
        "La aceleración es el cambio de velocidad por unidad de tiempo y se mide en metros por segundo al cuadrado (m/s²).",
        "En el movimiento rectilíneo uniforme (MRU) la velocidad es constante y la aceleración es cero.",
        "En la caída libre los cuerpos aceleran con g = 9,8 m/s² cerca de la superficie de la Tierra.",
    ])?;
    mk(&fis.id, "Leyes de Newton", &[
        "Primera ley o ley de inercia: un cuerpo permanece en reposo o en movimiento rectilíneo uniforme si la fuerza neta sobre él es cero.",
        "Segunda ley: la fuerza neta es igual a la masa por la aceleración (F = m·a). La fuerza se mide en newtons.",
        "Tercera ley: a toda acción le corresponde una reacción igual y de sentido contrario.",
    ])?;
    mk(&his.id, "Revolución Francesa", &[
        "La Revolución Francesa comenzó en 1789 con la toma de la Bastilla el 14 de julio.",
        "La Declaración de los Derechos del Hombre y del Ciudadano se aprobó en agosto de 1789.",
    ])?;

    ai.start_background()?;
    let t0 = Instant::now();
    loop {
        let st = ai.index_status()?;
        if st.pending_notes == 0 && st.chunk_count > 0 && st.embedded_chunk_count == st.chunk_count {
            println!("== índice: {} fragmentos con embeddings en {:.1}s (incluye carga del modelo)", st.chunk_count, t0.elapsed().as_secs_f64());
            break;
        }
        anyhow::ensure!(t0.elapsed() < Duration::from_secs(300), "indexación lenta: {st:?} {:?}", st.last_error);
        std::thread::sleep(Duration::from_millis(200));
    }

    let folder = |id: &str| AiScope { kind: ScopeKind::Folder, ids: vec![id.to_string()] };
    let opts = |detail, count, mix| StudyOptions { detail, count, quiz_mix: mix, title: None };

    let a = run("pregunta en Física", |s| {
        ai.ask(folder(&fis.id), "¿Qué dice la segunda ley de Newton y en qué unidad se mide la fuerza?".into(), None, s).unwrap();
    });
    println!("{}\n   citas: {:?}\n", a.text, a.citations.iter().map(|c| (c.n, c.note_title.as_str())).collect::<Vec<_>>());
    anyhow::ensure!(a.kind == AiEventKind::Done && !a.insufficient && !a.citations.is_empty(), "respuesta con citas");
    anyhow::ensure!(a.citations.iter().all(|c| c.location == vec!["Física".to_string()]), "citas solo del ámbito");

    let b = run("pregunta fuera de las fuentes", |s| {
        ai.ask(folder(&fis.id), "¿En qué año comenzó la Revolución Francesa?".into(), None, s).unwrap();
    });
    println!("{} (insufficient = {})\n", b.text, b.insufficient);

    let c = run("misma pregunta en Historia", |s| {
        ai.ask(folder(&his.id), "¿En qué año comenzó la Revolución Francesa?".into(), None, s).unwrap();
    });
    println!("{}\n", c.text);
    anyhow::ensure!(c.text.contains("1789"), "responde con la fuente de Historia");

    for (kind, o) in [
        (StudyKind::Summary, opts(DetailLevel::Brief, 5, QuizMix::Mixed)),
        (StudyKind::Flashcards, opts(DetailLevel::Brief, 5, QuizMix::Mixed)),
        (StudyKind::Quiz, opts(DetailLevel::Brief, 4, QuizMix::Mixed)),
    ] {
        let ev = run(&format!("{kind:?} de Física"), |s| {
            ai.generate_study(kind, folder(&fis.id), o, s).unwrap();
        });
        anyhow::ensure!(ev.kind == AiEventKind::Done, "{kind:?}: {}", ev.text);
        let item = store::get_study_item(&core.db.read(), ev.result_id.as_ref().unwrap())?;
        store::validate_content(kind, &item.content_json)?;
        let v: serde_json::Value = serde_json::from_str(&item.content_json)?;
        println!("{}\n", serde_json::to_string_pretty(&v).unwrap().chars().take(1800).collect::<String>());
        if kind == StudyKind::Quiz {
            if let Some(q) = v["questions"].as_array().unwrap().iter().find(|q| q["kind"] == "open") {
                let g = run("corrección de respuesta abierta", |s| {
                    ai.grade_open_answer(item.id.clone(), q["id"].as_str().unwrap().into(), "No lo sé, creo que tiene que ver con los colores.".into(), s).unwrap();
                });
                println!("{}\n", g.text);
            }
        }
    }
    println!("E2E OK");
    Ok(())
}
