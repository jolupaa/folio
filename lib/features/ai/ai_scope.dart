import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/navigation.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import 'ai_gateway.dart';

/// Clave con igualdad por valor para un [AiScope] (el DTO generado compara las listas por
/// identidad). Se usa como argumento de providers `family`.
@immutable
class ScopeRef {
  ScopeRef(AiScope scope) : kind = scope.kind, ids = List.unmodifiable(scope.ids);

  final ScopeKind kind;
  final List<String> ids;

  AiScope get scope => AiScope(kind: kind, ids: ids);

  @override
  bool operator ==(Object other) {
    if (other is! ScopeRef || other.kind != kind || other.ids.length != ids.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (other.ids[i] != ids[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(ids));

  @override
  String toString() => 'ScopeRef(${kind.name}, $ids)';
}

bool sameScope(AiScope a, AiScope b) => ScopeRef(a) == ScopeRef(b);

/// Opción del selector de ámbito («Esta nota» → carpeta → biblioteca).
@immutable
class ScopeOption {
  const ScopeOption({required this.scope, required this.label, required this.icon});

  final AiScope scope;
  final String label;
  final IconData icon;
}

IconData scopeIcon(ScopeKind kind) => switch (kind) {
  ScopeKind.note => Icons.description_rounded,
  ScopeKind.notes => Icons.library_add_check_rounded,
  ScopeKind.folder => Icons.folder_rounded,
  ScopeKind.library_ => Icons.local_library_rounded,
};

/// Etiqueta corta de un ámbito sin consultar a Rust (la etiqueta definitiva la da
/// `describe_scope`).
String fallbackScopeLabel(AiScope scope) => switch (scope.kind) {
  ScopeKind.note => 'Esta nota',
  ScopeKind.notes => Fmt.count(scope.ids.length, 'nota elegida', 'notas elegidas'),
  ScopeKind.folder => 'Carpeta',
  ScopeKind.library_ => 'Toda la biblioteca',
};

/// Escalera de ámbitos a partir del inicial: nota → su carpeta y las carpetas superiores →
/// biblioteca. Para una carpeta: ella y sus ancestros → biblioteca.
Future<List<ScopeOption>> buildScopeLadder(AiGateway gateway, AiScope initial) async {
  final out = <ScopeOption>[];
  String? folderId;
  switch (initial.kind) {
    case ScopeKind.note:
      out.add(ScopeOption(scope: initial, label: 'Esta nota', icon: scopeIcon(ScopeKind.note)));
      if (initial.ids.isNotEmpty) {
        try {
          folderId = await gateway.noteFolderId(initial.ids.first);
        } catch (_) {
          folderId = null;
        }
      }
    case ScopeKind.notes:
      out.add(ScopeOption(scope: initial, label: fallbackScopeLabel(initial), icon: scopeIcon(ScopeKind.notes)));
    case ScopeKind.folder:
      folderId = initial.ids.isEmpty ? null : initial.ids.first;
    case ScopeKind.library_:
      break;
  }
  if (folderId != null) {
    List<Folder> folders;
    try {
      folders = await gateway.listFolders();
    } catch (_) {
      folders = const [];
    }
    final byId = {for (final f in folders) f.id: f};
    final seen = <String>{};
    String? current = folderId;
    while (current != null && seen.add(current)) {
      final f = byId[current];
      out.add(
        ScopeOption(scope: Scopes.folder(current), label: f?.name ?? 'Carpeta', icon: scopeIcon(ScopeKind.folder)),
      );
      current = f?.parentId;
    }
  }
  out.add(const ScopeOption(scope: Scopes.library, label: 'Toda la biblioteca', icon: Icons.local_library_rounded));
  return out;
}

final scopeOptionsProvider = FutureProvider.autoDispose.family<List<ScopeOption>, ScopeRef>(
  (ref, key) => buildScopeLadder(ref.watch(aiGatewayProvider), key.scope),
  retry: noAutoRetry,
);

/// Resumen del ámbito (`describe_scope`). Se recalcula cuando el indexador informa de cambios
/// (`watch_index`), para que el aviso de notas pendientes se mantenga al día.
final scopeSummaryProvider = FutureProvider.autoDispose.family<ScopeSummary, ScopeRef>((ref, key) {
  ref.watch(
    indexStatusProvider.select(
      (s) => (s.value?.pendingNotes, s.value?.chunkCount, s.value?.embeddedChunkCount, s.value?.running),
    ),
  );
  return ref.watch(aiGatewayProvider).describeScope(key.scope);
}, retry: noAutoRetry);

/// «Física · 12 fuentes».
String scopeSummaryLine(ScopeSummary s) => '${s.label} · ${Fmt.count(s.noteCount, 'fuente', 'fuentes')}';

/// Aviso de indexación incompleta, o null si el índice está al día.
String? pendingIndexWarning(ScopeSummary s) {
  if (s.pendingNotes == 0) return null;
  final n = s.pendingNotes;
  return n == 1
      ? 'Hay 1 nota pendiente de indexar: puede que la IA aún no la tenga en cuenta.'
      : 'Hay $n notas pendientes de indexar: puede que la IA aún no las tenga en cuenta.';
}
