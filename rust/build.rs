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
}
