import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/errors.dart';

/// Mensaje legible para errores de captura, importación y OCR (espacio, E/S, plataforma, Rust).
String captureErrorMessage(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if (code == 28) return 'No queda espacio suficiente en el dispositivo.';
    if (code == 13 || code == 1) return 'Folio no tiene permiso para leer o escribir el fichero.';
    if (code == 2) return 'El fichero ya no existe.';
    return 'No se pudo acceder al fichero (${error.osError?.message ?? error.message}).';
  }
  if (error is MissingPluginException) {
    return 'Esta función no está disponible en este dispositivo.';
  }
  final msg = humanError(error);
  final lower = msg.toLowerCase();
  if (lower.contains('no space left') || lower.contains('enospc') || lower.contains('os error 28')) {
    return 'No queda espacio suficiente en el dispositivo.';
  }
  return msg.isEmpty ? 'Ha ocurrido un error inesperado.' : msg;
}
