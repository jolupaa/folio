//! iOS: el código Objective-C de llama.cpp (Metal) usa `@available`, que necesita
//! `___isPlatformVersionAtLeast` de la biblioteca de soporte de clang. rustc enlaza la biblioteca
//! dinámica con `-nodefaultlibs`, así que hay que añadirla a mano.

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os != "ios" {
        return;
    }
    let target = std::env::var("TARGET").unwrap_or_default();
    let simulator = target.ends_with("-sim") || target.starts_with("x86_64");
    let lib = if simulator { "clang_rt.iossim" } else { "clang_rt.ios" };

    let out = Command::new("xcrun").args(["clang", "--print-search-dirs"]).output();
    let dir = out.ok().filter(|o| o.status.success()).and_then(|o| {
        String::from_utf8_lossy(&o.stdout).lines().find_map(|l| {
            let rest = l.strip_prefix("libraries: =")?;
            rest.split(':').next().map(|d| format!("{}/lib/darwin", d.trim()))
        })
    });
    match dir {
        Some(d) => {
            // Es un archivo universal (varias arquitecturas): rustc no sabe incrustarlo, así que
            // se pasa tal cual al enlazador, y solo para la biblioteca dinámica (en la estática
            // lo añade Xcode al enlazar la app).
            println!("cargo:rustc-cdylib-link-arg={d}/lib{lib}.a");
        }
        None => println!("cargo:warning=no se encontró la biblioteca de soporte de clang ({lib})"),
    }

    link_httplib();
}

/// Xcode enlaza `libfolio_bridge.a` con `-force_load`, que carga todos los objetos, también el
/// código de descargas de llama.cpp (`common/download.cpp`) que la app no usa pero que referencia
/// cpp-httplib. llama-cpp-sys-2 compila esa biblioteca y no la enlaza: se añade aquí para que
/// quede dentro de la biblioteca estática.
fn link_httplib() {
    let Some(out) = std::env::var_os("OUT_DIR").map(std::path::PathBuf::from) else { return };
    // OUT_DIR = <target>/<triple>/<perfil>/build/folio_bridge-<hash>/out
    let Some(build_dir) = out.parent().and_then(|p| p.parent()) else { return };
    let mut found: Vec<(std::time::SystemTime, std::path::PathBuf)> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(build_dir) {
        for e in entries.flatten() {
            if !e.file_name().to_string_lossy().starts_with("llama-cpp-sys-2-") {
                continue;
            }
            let dir = e.path().join("out/build/vendor/cpp-httplib");
            if let Ok(meta) = std::fs::metadata(dir.join("libcpp-httplib.a")) {
                found.push((meta.modified().unwrap_or(std::time::UNIX_EPOCH), dir));
            }
        }
    }
    found.sort();
    match found.pop() {
        Some((_, dir)) => {
            println!("cargo:rustc-link-search=native={}", dir.display());
            println!("cargo:rustc-link-lib=static=cpp-httplib");
        }
        None => println!("cargo:warning=no se encontró libcpp-httplib.a de llama.cpp"),
    }
}
