//! iOS: el código Objective-C de llama.cpp (Metal) usa `@available`, que necesita
//! `___isPlatformVersionAtLeast` de la biblioteca de soporte de clang. rustc enlaza la biblioteca
//! dinámica con `-nodefaultlibs`, así que hay que añadirla a mano.

use std::{ffi::OsStr, path::PathBuf, process::Command};

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
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo debe proporcionar OUT_DIR"));
    // Cargo usa build/<paquete>-<hash>/out o build/<paquete>/<hash>/out.
    let build_dir = out
        .ancestors()
        .find(|path| path.file_name() == Some(OsStr::new("build")))
        .expect("no se encontró el directorio de compilación de Cargo");
    let mut dependency_dirs = Vec::new();
    for entry in std::fs::read_dir(build_dir).into_iter().flatten().flatten() {
        let name = entry.file_name();
        if name == "llama-cpp-sys-2" {
            dependency_dirs.extend(
                std::fs::read_dir(entry.path())
                    .into_iter()
                    .flatten()
                    .flatten()
                    .map(|entry| entry.path()),
            );
        } else if name.to_string_lossy().starts_with("llama-cpp-sys-2-") {
            dependency_dirs.push(entry.path());
        }
    }

    let (_, library) = dependency_dirs
        .into_iter()
        .map(|dir| dir.join("out/build/vendor/cpp-httplib/libcpp-httplib.a"))
        .filter_map(|library| Some((library.metadata().ok()?.modified().ok()?, library)))
        .max()
        .expect("llama-cpp-sys-2 debe generar libcpp-httplib.a antes de enlazar Folio");
    let directory = library.parent().expect("cpp-httplib debe estar en un directorio");
    println!("cargo:rerun-if-changed={}", library.display());
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=static=cpp-httplib");
}
