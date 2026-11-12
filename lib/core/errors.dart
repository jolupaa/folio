import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

/// Mensaje legible para el usuario a partir de un error de Rust, de plataforma o de Dart.
String humanError(Object error) {
  if (error is AnyhowException) {
    // anyhow incluye la cadena de contexto; mostramos la primera línea.
    return error.message.split('\n').first.trim();
  }
  if (error is PlatformException) {
    return switch (error.code) {
      'permission_denied' => 'Permiso denegado. Puedes activarlo en Ajustes.',
      'unsupported' => 'Esta función no está disponible en este dispositivo.',
      'cancelled' => 'Operación cancelada.',
      _ => error.message ?? 'Error del sistema (${error.code}).',
    };
  }
  final s = error.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

void showErrorSnack(BuildContext context, Object error, {String? prefix}) {
  final msg = humanError(error);
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(prefix == null ? msg : '$prefix: $msg')));
}

void showInfoSnack(BuildContext context, String message, {SnackBarAction? action}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message), action: action));
}
