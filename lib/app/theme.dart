import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Tokens de color de Folio (docs/DESIGN.md §1). Accesibles con `context.colors`.
@immutable
class FolioColors extends ThemeExtension<FolioColors> {
  const FolioColors({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.separator,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.danger,
    required this.highlight,
  });

  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color separator;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color danger;
  final Color highlight;

  static const light = FolioColors(
    background: Color(0xFFF4F3EF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFECEAE5),
    separator: Color(0xFFE2DFD8),
    textPrimary: Color(0xFF1C1B19),
    textSecondary: Color(0xFF67645E),
    textTertiary: Color(0xFF8E8A83),
    accent: Color(0xFF2F6F5E),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x1A2F6F5E),
    danger: Color(0xFFB3261E),
    highlight: Color(0xFFF6E7A8),
  );

  static const dark = FolioColors(
    background: Color(0xFF121211),
    surface: Color(0xFF1C1C1A),
    surfaceAlt: Color(0xFF262624),
    separator: Color(0xFF33322E),
    textPrimary: Color(0xFFECEAE4),
    textSecondary: Color(0xFFA3A098),
    textTertiary: Color(0xFF7A776F),
    accent: Color(0xFF7FC4AE),
    onAccent: Color(0xFF0E2A22),
    accentSoft: Color(0x247FC4AE),
    danger: Color(0xFFF2B8B5),
    highlight: Color(0xFF5C4F1A),
  );

  @override
  FolioColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? separator,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? danger,
    Color? highlight,
  }) {
    return FolioColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      separator: separator ?? this.separator,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      danger: danger ?? this.danger,
      highlight: highlight ?? this.highlight,
    );
  }

  @override
  FolioColors lerp(ThemeExtension<FolioColors>? other, double t) {
    if (other is! FolioColors) return this;
    return FolioColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      highlight: Color.lerp(highlight, other.highlight, t)!,
    );
  }
}

/// Espaciado y forma (docs/DESIGN.md §3).
abstract final class Insets {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double gutter = 16;
  static const double minTouch = 48;
  static const double radiusGroup = 12;
  static const double radiusSheet = 20;
  static const double radiusButton = 12;
}

/// Duraciones de animación (docs/DESIGN.md §4).
abstract final class Motion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 220);
  static const curve = Curves.easeOutCubic;

  /// Duración efectiva respetando «reducir movimiento».
  static Duration of(BuildContext context, [Duration d = normal]) =>
      MediaQuery.of(context).disableAnimations ? Duration.zero : d;
}

extension FolioThemeContext on BuildContext {
  FolioColors get colors => Theme.of(this).extension<FolioColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
  bool get isCupertino {
    final p = Theme.of(this).platform;
    return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
  }
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? FolioColors.light : FolioColors.dark;
  final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.textPrimary,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.danger,
    onError: brightness == Brightness.light ? Colors.white : const Color(0xFF601410),
    surface: c.surface,
    onSurface: c.textPrimary,
    onSurfaceVariant: c.textSecondary,
    surfaceContainerLowest: c.background,
    surfaceContainerLow: c.background,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceAlt,
    surfaceContainerHighest: c.surfaceAlt,
    outline: c.separator,
    outlineVariant: c.separator,
  );

  // Escala tipográfica (docs/DESIGN.md §2). Fuente del sistema.
  final body = isIOS ? 17.0 : 16.0;
  TextStyle s(double size, FontWeight w, double h, Color color) =>
      TextStyle(fontSize: size, fontWeight: w, height: h, color: color, letterSpacing: 0);
  final textTheme = TextTheme(
    displaySmall: s(32, FontWeight.w700, 1.15, c.textPrimary), // largeTitle
    headlineSmall: s(22, FontWeight.w600, 1.25, c.textPrimary), // title
    titleLarge: s(22, FontWeight.w600, 1.25, c.textPrimary),
    titleMedium: s(17, FontWeight.w600, 1.3, c.textPrimary), // headline
    titleSmall: s(15, FontWeight.w600, 1.3, c.textPrimary),
    bodyLarge: s(body, FontWeight.w400, isIOS ? 1.45 : 1.5, c.textPrimary), // body
    bodyMedium: s(15, FontWeight.w400, 1.4, c.textPrimary), // callout
    bodySmall: s(13, FontWeight.w400, 1.35, c.textSecondary), // footnote
    labelLarge: s(15, FontWeight.w600, 1.2, c.textPrimary),
    labelMedium: s(13, FontWeight.w500, 1.3, c.textSecondary),
    labelSmall: s(12, FontWeight.w500, 1.3, c.textSecondary), // caption
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    textTheme: textTheme,
    extensions: [c],
    splashFactory: isIOS ? NoSplash.splashFactory : InkSparkle.splashFactory,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    dividerTheme: DividerThemeData(color: c.separator, thickness: 0.6, space: 0.6),
    iconTheme: IconThemeData(color: c.accent, size: 24),
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: c.accent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: isIOS,
      titleTextStyle: textTheme.titleMedium,
      iconTheme: IconThemeData(color: c.accent),
    ),
    listTileTheme: ListTileThemeData(
      tileColor: c.surface,
      iconColor: c.accent,
      textColor: c.textPrimary,
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      titleTextStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
      subtitleTextStyle: textTheme.bodySmall,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.separator,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Insets.radiusSheet)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Insets.radiusSheet)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        minimumSize: const Size(Insets.minTouch, Insets.minTouch),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Insets.radiusButton)),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(Insets.minTouch, Insets.minTouch),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.accent,
        side: BorderSide(color: c.separator),
        minimumSize: const Size(Insets.minTouch, Insets.minTouch),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Insets.radiusButton)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.accent,
        minimumSize: const Size(Insets.minTouch, Insets.minTouch),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceAlt,
      hintStyle: textTheme.bodyLarge?.copyWith(color: c.textTertiary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Insets.radiusButton),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: Insets.md),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceAlt,
      selectedColor: c.accentSoft,
      labelStyle: textTheme.labelMedium?.copyWith(color: c.textPrimary),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.textPrimary,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: c.background),
      actionTextColor: brightness == Brightness.light ? const Color(0xFF9FD8C6) : c.onAccent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Insets.radiusButton)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.surfaceAlt),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onAccent : null,
      ),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : null),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.25),
      selectionHandleColor: c.accent,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
