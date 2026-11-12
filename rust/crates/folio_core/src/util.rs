//! Utilidades comunes: tiempo, identificadores y texto.

/// Milisegundos Unix UTC.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// UUID v4 en minúsculas.
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Primeros `max` caracteres (no bytes) de `s`.
pub fn truncate_chars(s: &str, max: usize) -> &str {
    match s.char_indices().nth(max) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

/// Normaliza un texto de una línea (títulos, nombres): saltos y tabuladores → espacio,
/// sin caracteres de control, espacios extremos recortados, máximo `max_chars` caracteres.
pub fn single_line(s: &str, max_chars: usize) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| if c == '\n' || c == '\r' || c == '\t' { ' ' } else { c })
        .filter(|c| !c.is_control())
        .collect();
    truncate_chars(cleaned.trim(), max_chars).trim_end().to_string()
}

/// Fecha local (año, mes 1..=12, día) de un instante en milisegundos Unix.
/// Usa la zona horaria del sistema (localtime_r, disponible en Android e iOS).
pub fn local_ymd(ms: i64) -> (i32, u32, u32) {
    let secs = ms.div_euclid(1000) as libc::time_t;
    // SAFETY: `tm` es POD; localtime_r solo escribe en él y devuelve NULL si falla.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if !libc::localtime_r(&secs, &mut tm).is_null() {
            return (tm.tm_year + 1900, (tm.tm_mon + 1) as u32, tm.tm_mday as u32);
        }
    }
    civil_from_days(ms.div_euclid(super::model::DAY_MS))
}

/// Algoritmo de H. Hinnant: días desde 1970-01-01 → fecha civil UTC.
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

const MONTHS_ES: [&str; 12] =
    ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"];

/// Fecha corta en español: «11 nov 2026».
pub fn short_date_es(ms: i64) -> String {
    let (y, m, d) = local_ymd(ms);
    format!("{d} {} {y}", MONTHS_ES[(m.clamp(1, 12) - 1) as usize])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        // 2026-11-11 = 20768 días desde la época.
        assert_eq!(civil_from_days(20_768), (2026, 11, 11));
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
    }

    #[test]
    fn text_helpers() {
        assert_eq!(truncate_chars("ñandú", 3), "ñan");
        assert_eq!(truncate_chars("ab", 5), "ab");
        assert_eq!(single_line("  Hola\nmundo\t ", 100), "Hola mundo");
        assert_eq!(single_line("abcdef", 3), "abc");
        let label = short_date_es(1_794_398_400_000); // 2026-11-11T12:00Z
        assert!(label.ends_with("2026"), "{label}");
    }
}
