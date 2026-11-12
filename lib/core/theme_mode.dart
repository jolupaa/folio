import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/app.dart' as app;

const _key = 'theme_mode';

/// Tema elegido en Ajustes (sistema, claro u oscuro). Se guarda en la base de datos local.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    try {
      final v = await app.getSetting(key: _key);
      final m = ThemeMode.values.where((e) => e.name == v).firstOrNull;
      if (m != null) state = m;
    } catch (_) {
      // Sin ajuste guardado o base de datos no disponible: se sigue el tema del sistema.
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await app.setSetting(key: _key, value: mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
