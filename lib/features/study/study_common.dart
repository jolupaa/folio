import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../core/navigation.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../ai/citation_widgets.dart' show DeletedSourceBadge;
import 'study_gateway.dart';
import 'study_labels.dart';
import 'study_models.dart';

/// Guarda título y contenido (`update_study_item`). Devuelve false y avisa si falla.
Future<bool> saveStudyItem(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String title,
  required StudyContent content,
}) async {
  try {
    await ref.read(studyGatewayProvider).updateItem(id, title: title.trim(), contentJson: content.encode());
    ref.read(studyRevisionProvider.notifier).bump();
    return true;
  } catch (e) {
    if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo guardar');
    return false;
  }
}

/// Línea de metadatos: «Resumen · Física · 12 nov».
class StudyMetaLine extends StatelessWidget {
  const StudyMetaLine({super.key, required this.item, this.extra});

  final StudyItem item;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final parts = [
      studyKindLabel(item.kind),
      if (item.scopeLabel.isNotEmpty) item.scopeLabel,
      ?extra,
      Fmt.relativeDate(item.updatedAt),
    ];
    return Row(
      children: [
        Icon(studyKindIcon(item.kind), size: 18, color: context.colors.textSecondary),
        const SizedBox(width: Insets.sm),
        Expanded(child: Text(parts.join(' · '), style: context.text.bodySmall)),
      ],
    );
  }
}

/// Lista de fuentes del material (nota y si sigue existiendo).
class SourcesSection extends StatelessWidget {
  const SourcesSection({super.key, required this.sources});

  final List<SourceRef> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              sources.length == 1 ? 'Fuente' : 'Fuentes (${sources.length})',
              style: context.text.titleMedium,
            ),
          ),
          const SizedBox(height: Insets.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(Insets.radiusGroup),
            child: Material(
              color: c.surface,
              child: Column(
                children: [
                  for (var i = 0; i < sources.length; i++) ...[
                    if (i > 0) Divider(indent: Insets.lg + 40, height: 0.6, color: c.separator),
                    SourceTile(source: sources[i]),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SourceTile extends StatelessWidget {
  const SourceTile({super.key, required this.source, this.onOpen});

  final SourceRef source;

  /// Acción al tocar; por defecto abre la nota.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = source;
    final title = s.title.trim().isEmpty ? 'Nota sin título' : s.title.trim();
    return ListTile(
      leading: Icon(
        s.exists ? Icons.description_outlined : Icons.link_off_rounded,
        color: s.exists ? c.accent : c.textTertiary,
      ),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: s.exists ? null : TextStyle(color: c.textSecondary, decoration: TextDecoration.lineThrough),
      ),
      subtitle: s.exists ? null : const DeletedSourceBadge(),
      trailing: s.exists ? Icon(Icons.chevron_right_rounded, color: c.textTertiary) : null,
      enabled: s.exists,
      onTap: s.exists ? (onOpen ?? () => context.openNote(s.noteId)) : null,
    );
  }
}

/// Hoja con las fuentes (accesible desde el menú en cualquier modo).
Future<void> showSourcesSheet(BuildContext context, List<SourceRef> sources) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.7),
      child: sources.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(Insets.xl),
              child: Text('Este material no tiene fuentes registradas.', style: sheet.text.bodyMedium),
            )
          : ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: Insets.xl),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Insets.gutter, 0, Insets.gutter, Insets.sm),
                  child: Semantics(header: true, child: Text('Fuentes', style: sheet.text.titleMedium)),
                ),
                for (final s in sources)
                  SourceTile(
                    source: s,
                    onOpen: () {
                      Navigator.pop(sheet);
                      if (context.mounted) context.openNote(s.noteId);
                    },
                  ),
              ],
            ),
    ),
  );
}

/// Andamio de los editores: «Cancelar»/«Guardar» y aviso de cambios sin guardar.
class EditorScaffold extends StatelessWidget {
  const EditorScaffold({
    super.key,
    required this.title,
    required this.dirty,
    required this.saving,
    required this.onSave,
    required this.body,
    this.bottom,
  });

  final String title;
  final bool dirty;
  final bool saving;
  final VoidCallback? onSave;
  final Widget body;
  final Widget? bottom;

  Future<void> _maybeLeave(BuildContext context) async {
    final discard = await confirmAction(
      context,
      title: '¿Descartar los cambios?',
      message: 'Los cambios que no has guardado se perderán.',
      confirmLabel: 'Descartar',
      destructive: true,
    );
    if (discard && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !dirty || saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _maybeLeave(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: IconButton(
            tooltip: 'Cancelar',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.maybePop(context),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: Insets.sm),
              child: saving
                  ? const Padding(
                      padding: EdgeInsets.all(Insets.md),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: 'Guardando'),
                      ),
                    )
                  : TextButton(onPressed: onSave, child: const Text('Guardar')),
            ),
          ],
        ),
        body: body,
        bottomNavigationBar: bottom,
      ),
    );
  }
}

/// Muestra un error de validación del editor.
void showValidation(BuildContext context, String message) => showInfoSnack(context, message);
