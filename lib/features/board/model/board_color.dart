import 'dart:ui';

/// Conversión de colores de la escena (`#RRGGBBAA`, docs/CONTRATOS.md §2) y paleta de la pizarra.
abstract final class BoardColors {
  /// Color de tinta por defecto (textPrimary claro). Se muestra con textPrimary oscuro en modo oscuro.
  static const ink = Color(0xFF1C1B19);

  /// Alfa del marcador (≈ 50 %), como en el ejemplo del contrato (`#F6E7A880`).
  static const highlighterAlpha = 0x80;

  /// `#RRGGBBAA` en mayúsculas.
  static String format(Color color) {
    final argb = color.toARGB32();
    final a = (argb >> 24) & 0xFF;
    final rgb = argb & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}${a.toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();
  }

  /// Acepta `#RRGGBBAA` (contrato) y, por tolerancia, `#RRGGBB` (opaco). Null si no es válido.
  static Color? tryParse(Object? value) {
    if (value is! String) return null;
    var s = value.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length != 6 && s.length != 8) return null;
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    if (s.length == 6) return Color(0xFF000000 | v);
    final rgb = (v >> 8) & 0xFFFFFF;
    final a = v & 0xFF;
    return Color((a << 24) | rgb);
  }

  static Color parse(Object? value, {Color fallback = ink}) => tryParse(value) ?? fallback;

  static int alphaOf(Color c) => (c.toARGB32() >> 24) & 0xFF;

  static Color withAlpha8(Color c, int alpha) => Color((alpha.clamp(0, 255) << 24) | (c.toARGB32() & 0xFFFFFF));

  /// Color con el que se dibuja `stored` en el modo actual. Los colores de la paleta se guardan con
  /// su variante clara (canónica) y se muestran con su variante oscura en modo oscuro (y al revés si
  /// se encontrara una variante oscura guardada). El alfa se conserva. Otros colores, tal cual.
  static Color display(Color stored, Brightness brightness) {
    final argb = stored.toARGB32();
    final rgb = argb & 0xFFFFFF;
    final alpha = argb & 0xFF000000;
    for (final entry in boardPalette) {
      final from = brightness == Brightness.dark ? entry.light : entry.dark;
      if ((from.toARGB32() & 0xFFFFFF) == rgb) {
        final to = brightness == Brightness.dark ? entry.dark : entry.light;
        return Color(alpha | (to.toARGB32() & 0xFFFFFF));
      }
    }
    return stored;
  }

  /// Índice de la paleta cuyo color (claro u oscuro) coincide con `c` (ignorando alfa), o -1.
  static int paletteIndexOf(Color c) {
    final rgb = c.toARGB32() & 0xFFFFFF;
    for (var i = 0; i < boardPalette.length; i++) {
      final e = boardPalette[i];
      if ((e.light.toARGB32() & 0xFFFFFF) == rgb || (e.dark.toARGB32() & 0xFFFFFF) == rgb) return i;
    }
    return -1;
  }
}

/// Color de la paleta con su variante para modo oscuro.
class BoardPaletteEntry {
  const BoardPaletteEntry(this.label, this.light, this.dark);

  /// Nombre accesible («Tinta», «Rojo»…).
  final String label;
  final Color light;
  final Color dark;

  Color forBrightness(Brightness b) => b == Brightness.dark ? dark : light;
}

/// Paleta de 8 colores: tinta, acento, rojo, naranja, amarillo, verde, azul, morado.
/// La tinta y el acento coinciden con los tokens `textPrimary` y `accent` (docs/DESIGN.md §1).
const boardPalette = <BoardPaletteEntry>[
  BoardPaletteEntry('Tinta', Color(0xFF1C1B19), Color(0xFFECEAE4)),
  BoardPaletteEntry('Acento', Color(0xFF2F6F5E), Color(0xFF7FC4AE)),
  BoardPaletteEntry('Rojo', Color(0xFFC53B30), Color(0xFFF2958C)),
  BoardPaletteEntry('Naranja', Color(0xFFD9741C), Color(0xFFF5B26E)),
  BoardPaletteEntry('Amarillo', Color(0xFFE8B400), Color(0xFFF2D46B)),
  BoardPaletteEntry('Verde', Color(0xFF3F8A3F), Color(0xFF8FCF8C)),
  BoardPaletteEntry('Azul', Color(0xFF2E63C2), Color(0xFF8AB4F8)),
  BoardPaletteEntry('Morado', Color(0xFF7A4CB8), Color(0xFFC5A8F0)),
];
