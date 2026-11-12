//! Información del dispositivo: RAM, núcleos, espacio libre y compatibilidad de CPU.

use crate::catalog::ModelSpec;
use crate::types::{DeviceInfo, ModelRole};
use std::path::Path;

/// Medidas del dispositivo (inyectables en tests).
#[derive(Clone, Debug, PartialEq)]
pub struct DeviceSnapshot {
    pub total_ram: u64,
    pub available_ram: u64,
    pub cpu_cores: u32,
    /// Núcleos de rendimiento (big/prime). Igual a `cpu_cores` si no se puede distinguir.
    pub performance_cores: u32,
    pub free_storage: u64,
    /// Motivo legible si la CPU no puede ejecutar el motor compilado (p. ej. falta dotprod).
    pub cpu_incompatibility: Option<String>,
}

impl DeviceSnapshot {
    pub fn probe(data_dir: &Path) -> DeviceSnapshot {
        let cores = cpu_cores();
        let total = total_ram().unwrap_or(0);
        DeviceSnapshot {
            total_ram: total,
            available_ram: available_ram().unwrap_or(total / 2),
            cpu_cores: cores,
            performance_cores: performance_cores().unwrap_or(cores).clamp(1, cores.max(1)),
            free_storage: free_space(data_dir).unwrap_or(0),
            cpu_incompatibility: cpu_incompatibility(),
        }
    }

    pub fn supports(&self, spec: &ModelSpec) -> bool {
        self.cpu_incompatibility.is_none() && self.total_ram >= spec.min_ram_bytes as u64
    }
}

pub fn cpu_cores() -> u32 {
    std::thread::available_parallelism().map(|n| n.get() as u32).unwrap_or(1)
}

/// Espacio libre (bytes disponibles para usuarios sin privilegios) del volumen de `path`.
pub fn free_space(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let mut p = path.to_path_buf();
    // statvfs necesita una ruta existente: sube hasta encontrar un ancestro que exista.
    while !p.exists() {
        if !p.pop() {
            return None;
        }
    }
    let c = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` es una cadena C válida y `st` un búfer del tamaño correcto.
    let r = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if r != 0 {
        return None;
    }
    #[allow(clippy::unnecessary_cast)]
    Some(st.f_bavail as u64 * st.f_frsize as u64)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn meminfo_kib(key: &str) -> Option<u64> {
    let s = std::fs::read_to_string("/proc/meminfo").ok()?;
    s.lines().find_map(|l| {
        let rest = l.strip_prefix(key)?.strip_prefix(':')?;
        rest.trim().trim_end_matches("kB").trim().parse::<u64>().ok()
    })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn total_ram() -> Option<u64> {
    meminfo_kib("MemTotal").map(|k| k * 1024)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn available_ram() -> Option<u64> {
    meminfo_kib("MemAvailable").map(|k| k * 1024)
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
fn sysctl_u64(name: &str) -> Option<u64> {
    let c = std::ffi::CString::new(name).ok()?;
    let mut buf = [0u8; 8];
    let mut size: libc::size_t = buf.len();
    // SAFETY: búfer de 8 bytes y tamaño correcto; sysctl escribe como mucho `size` bytes.
    let r = unsafe {
        libc::sysctlbyname(
            c.as_ptr(),
            buf.as_mut_ptr() as *mut libc::c_void,
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if r != 0 {
        return None;
    }
    match size {
        4 => Some(u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]) as u64),
        8 => Some(u64::from_ne_bytes(buf)),
        _ => None,
    }
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
pub fn total_ram() -> Option<u64> {
    sysctl_u64("hw.memsize")
}

#[cfg(target_os = "ios")]
extern "C" {
    // <os/proc.h>, iOS 13+: memoria que la app puede reservar antes de alcanzar su límite (jetsam).
    fn os_proc_available_memory() -> libc::size_t;
}

#[cfg(target_os = "ios")]
pub fn available_ram() -> Option<u64> {
    // SAFETY: función sin argumentos de libSystem disponible desde iOS 13 (objetivo mínimo: 16).
    let v = unsafe { os_proc_available_memory() } as u64;
    if v > 0 {
        Some(v)
    } else {
        None
    }
}

#[cfg(target_os = "macos")]
pub fn available_ram() -> Option<u64> {
    None
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios", target_os = "macos")))]
pub fn total_ram() -> Option<u64> {
    None
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios", target_os = "macos")))]
pub fn available_ram() -> Option<u64> {
    None
}

/// Núcleos de rendimiento. Android/Linux: núcleos cuya frecuencia máxima supera la del clúster
/// más lento (big.LITTLE); si todos son iguales, todos. iOS: `hw.perflevel0.physicalcpu`.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn performance_cores() -> Option<u32> {
    let n = cpu_cores();
    let mut freqs = Vec::new();
    for i in 0..n {
        let p = format!("/sys/devices/system/cpu/cpu{i}/cpufreq/cpuinfo_max_freq");
        if let Some(f) = std::fs::read_to_string(p).ok().and_then(|s| s.trim().parse::<u64>().ok()) {
            freqs.push(f);
        }
    }
    if freqs.len() as u32 != n || freqs.is_empty() {
        return None;
    }
    let min = *freqs.iter().min()?;
    let fast = freqs.iter().filter(|&&f| f > min).count() as u32;
    Some(if fast == 0 { n } else { fast })
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
pub fn performance_cores() -> Option<u32> {
    sysctl_u64("hw.perflevel0.physicalcpu").map(|v| v as u32).filter(|&v| v > 0)
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "ios", target_os = "macos")))]
pub fn performance_cores() -> Option<u32> {
    None
}

/// Arquitectura ARM con la que se compiló ggml (variable de entorno `GGML_CPU_ARM_ARCH` de la
/// compilación, p. ej. `armv8.2-a+dotprod`). `None` = valor por defecto de llama-cpp-sys (armv8-a).
pub fn compiled_arm_arch() -> Option<&'static str> {
    option_env!("GGML_CPU_ARM_ARCH")
}

/// En Android aarch64, si ggml se compiló con instrucciones dotprod (ARMv8.2), un procesador sin
/// ellas abortaría con SIGILL: se detecta antes con `getauxval(AT_HWCAP) & HWCAP_ASIMDDP`.
#[cfg(all(target_os = "android", target_arch = "aarch64"))]
pub fn cpu_incompatibility() -> Option<String> {
    let needs_dotprod = compiled_arm_arch().is_some_and(|a| a.contains("dotprod") || a.contains("v8.4") || a.contains("v8.6") || a.contains("v9"));
    if !needs_dotprod {
        return None;
    }
    // SAFETY: getauxval es segura para cualquier tipo; devuelve 0 si no existe.
    let hwcap = unsafe { libc::getauxval(libc::AT_HWCAP) };
    if hwcap & libc::HWCAP_ASIMDDP == 0 {
        Some("El procesador de este dispositivo no admite las instrucciones necesarias para la IA local (ARMv8.2 dotprod).".into())
    } else {
        None
    }
}

#[cfg(not(all(target_os = "android", target_arch = "aarch64")))]
pub fn cpu_incompatibility() -> Option<String> {
    None
}

/// Formato es-ES en GB (base 10, como muestran los sistemas): «2,7 GB», «640 MB».
pub fn format_bytes(bytes: u64) -> String {
    let gb = bytes as f64 / 1e9;
    if gb >= 1.0 {
        format!("{:.1} GB", gb).replace('.', ",")
    } else {
        format!("{} MB", (bytes as f64 / 1e6).round() as u64)
    }
}

/// RAM nominal en GB (redondeo hacia arriba a la clase comercial: 7,4 GiB → «8 GB»).
pub fn nominal_ram_gb(bytes: u64) -> u64 {
    let gib = bytes as f64 / (1024.0 * 1024.0 * 1024.0);
    for class in [1u64, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64] {
        if gib <= class as f64 * 1.0001 {
            return class;
        }
    }
    gib.ceil() as u64
}

/// Construye la información visible del dispositivo y la recomendación de modelo.
pub fn device_info(snap: &DeviceSnapshot, catalog: &[ModelSpec]) -> DeviceInfo {
    let mut llms: Vec<&ModelSpec> = catalog.iter().filter(|m| m.role == ModelRole::Llm).collect();
    llms.sort_by(|a, b| b.capability.cmp(&a.capability));
    let recommended = llms.iter().find(|m| snap.supports(m)).map(|m| m.id.clone());
    let can_run = recommended.is_some();
    let mut notes = Vec::new();
    if let Some(reason) = &snap.cpu_incompatibility {
        notes.push(reason.clone());
    } else if snap.total_ram > 0 {
        notes.push(format!(
            "Memoria RAM: {} ({} libres ahora).",
            format_bytes(snap.total_ram),
            format_bytes(snap.available_ram)
        ));
        for m in &llms {
            if !snap.supports(m) {
                notes.push(format!(
                    "RAM insuficiente para el modelo {} ({}): necesita un móvil de {} GB o más.",
                    m.tier_label,
                    m.display_name,
                    nominal_ram_gb(m.min_ram_bytes as u64)
                ));
            }
        }
        match llms.iter().find(|m| snap.supports(m)) {
            Some(m) => notes.push(format!("Modelo aconsejado para este dispositivo: {} ({}).", m.display_name, m.tier_label)),
            None => notes.push(
                "Este dispositivo no tiene memoria suficiente para los modelos de IA. Notas, búsqueda, \
                 escaneo y pizarra siguen funcionando con normalidad."
                    .into(),
            ),
        }
    } else {
        notes.push("No se ha podido medir la memoria del dispositivo.".into());
    }
    if let Some(m) = recommended.as_ref().and_then(|id| catalog.iter().find(|m| &m.id == id)) {
        if snap.free_storage < m.size_bytes as u64 {
            notes.push(format!(
                "Espacio libre insuficiente para descargar {}: se necesitan {}.",
                m.display_name,
                format_bytes(m.size_bytes as u64)
            ));
        }
    }
    if cfg!(target_os = "android") && can_run {
        notes.push("En Android la IA se ejecuta en el procesador: las respuestas largas pueden tardar.".into());
    }
    DeviceInfo {
        platform: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        total_ram_bytes: snap.total_ram as i64,
        available_ram_bytes: snap.available_ram as i64,
        cpu_cores: snap.cpu_cores,
        free_storage_bytes: snap.free_storage as i64,
        recommended_llm_id: recommended,
        can_run_any_llm: can_run,
        notes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::default_catalog;

    fn snap(total_gib: f64) -> DeviceSnapshot {
        let total = (total_gib * 1024.0 * 1024.0 * 1024.0) as u64;
        DeviceSnapshot {
            total_ram: total,
            available_ram: total / 2,
            cpu_cores: 8,
            performance_cores: 4,
            free_storage: 50_000_000_000,
            cpu_incompatibility: None,
        }
    }

    #[test]
    fn recommends_by_ram_class() {
        let c = default_catalog();
        // Móvil de «8 GB» (7,4 GiB reportados) → 4B.
        let d = device_info(&snap(7.4), &c);
        assert_eq!(d.recommended_llm_id.as_deref(), Some(crate::catalog::QWEN35_4B));
        assert!(d.can_run_any_llm);
        // Móvil de «6 GB» (5,5 GiB) → 2B y nota explicando el 4B.
        let d = device_info(&snap(5.5), &c);
        assert_eq!(d.recommended_llm_id.as_deref(), Some(crate::catalog::QWEN35_2B));
        assert!(d.notes.iter().any(|n| n.contains("Recomendado") && n.contains("8 GB")), "{:?}", d.notes);
        // «4 GB» → ninguno.
        let d = device_info(&snap(3.6), &c);
        assert!(d.recommended_llm_id.is_none());
        assert!(!d.can_run_any_llm);
        // CPU incompatible → ninguno aunque sobre RAM.
        let mut s = snap(12.0);
        s.cpu_incompatibility = Some("sin dotprod".into());
        let d = device_info(&s, &c);
        assert!(!d.can_run_any_llm);
        assert_eq!(d.notes[0], "sin dotprod");
    }

    #[test]
    fn formats_es() {
        assert_eq!(format_bytes(2_740_937_888), "2,7 GB");
        assert_eq!(format_bytes(639_150_592), "639 MB");
        assert_eq!(nominal_ram_gb(7_900_000_000), 8);
        assert_eq!(nominal_ram_gb(5_800_000_000), 6);
    }

    #[test]
    fn probes_host() {
        let dir = tempfile::tempdir().unwrap();
        let s = DeviceSnapshot::probe(dir.path());
        assert!(s.cpu_cores >= 1);
        assert!(s.free_storage > 0);
        assert!(free_space(&dir.path().join("no/existe/aun")).is_some());
        #[cfg(target_os = "linux")]
        assert!(s.total_ram > 0 && s.available_ram > 0);
    }
}
