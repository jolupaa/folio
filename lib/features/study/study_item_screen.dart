import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/providers.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/empty_state.dart';
import '../ai/skeleton.dart';
import 'flashcards.dart';
import 'quiz.dart';
import 'study_common.dart';
import 'study_gateway.dart';
import 'study_labels.dart';
import 'study_models.dart';
import 'text_material.dart';

/// Visor/editor de un material de estudio según su tipo.
class StudyItemScreen extends ConsumerWidget {
  const StudyItemScreen({super.key, required this.studyId});

  final String studyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(studyItemProvider(studyId));
    final value = item.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          value == null ? 'Material de estudio' : (value.title.isEmpty ? studyKindLabel(value.kind) : value.title),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [if (value != null) _Menu(item: value)],
      ),
      body: item.when(
        skipLoadingOnRefresh: true,
        loading: () => const SkeletonParagraphs(label: 'Cargando material'),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudo abrir el material',
          message: humanError(e),
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(studyItemProvider(studyId)),
          secondaryLabel: 'Volver',
          onSecondary: () => context.canPop() ? context.pop() : context.go('/study'),
        ),
        data: (it) => _StudyBody(item: it),
      ),
    );
  }
}

/// Abre el editor del tipo correspondiente.
Future<void> openStudyEditor(BuildContext context, StudyItem item) {
  final content = StudyContent.parse(item.kind, item.contentJson);
  final Widget editor = switch (content) {
    TextContent() => TextMaterialEditor(item: item, content: content),
    FlashcardsContent() => FlashcardsEditor(item: item, content: content),
    QuizContent() => QuizEditor(item: item, content: content),
  };
  return Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor));
}

class _StudyBody extends StatelessWidget {
  const _StudyBody({required this.item});
  final StudyItem item;

  @override
  Widget build(BuildContext context) {
    final content = StudyContent.parse(item.kind, item.contentJson);
    void edit() => openStudyEditor(context, item);
    return switch (content) {
      TextContent() => TextMaterialView(item: item, content: content, onEdit: edit),
      FlashcardsContent() => FlashcardsView(item: item, content: content, onEdit: edit),
      QuizContent() => QuizView(key: ValueKey('quiz-${item.id}'), item: item, content: content, onEdit: edit),
    };
  }
}

class _Menu extends ConsumerWidget {
  const _Menu({required this.item});
  final StudyItem item;

  String get _editLabel => switch (item.kind) {
    StudyKind.flashcards => 'Editar tarjetas',
    StudyKind.quiz => 'Editar preguntas',
    _ => 'Editar',
  };

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final title = await promptText(context, title: 'Renombrar', initial: item.title, confirmLabel: 'Guardar');
    if (title == null || title == item.title || !context.mounted) return;
    try {
      await ref.read(studyGatewayProvider).updateItem(item.id, title: title, contentJson: item.contentJson);
      ref.read(studyRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo renombrar');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirmAction(
      context,
      title: '¿Borrar «${item.title}»?',
      message:
          'Se eliminará este material${item.kind == StudyKind.quiz ? ' y sus intentos' : ''}. Tus notas no se modifican.',
      confirmLabel: 'Borrar',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(studyGatewayProvider).deleteItem(item.id);
      ref.read(studyRevisionProvider.notifier).bump();
      ref.read(libraryRevisionProvider.notifier).bump();
      if (!context.mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/study');
      }
    } catch (e) {
      if (context.mounted) showErrorSnack(context, e, prefix: 'No se pudo borrar');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final danger = context.colors.danger;
    return PopupMenuButton<String>(
      tooltip: 'Más opciones',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (v) => switch (v) {
        'edit' => openStudyEditor(context, item),
        'rename' => _rename(context, ref),
        'sources' => showSourcesSheet(context, item.sources),
        'delete' => _delete(context, ref),
        _ => null,
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'edit',
          child: ListTile(leading: const Icon(Icons.edit_note_rounded), title: Text(_editLabel)),
        ),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(leading: Icon(Icons.drive_file_rename_outline_rounded), title: Text('Renombrar')),
        ),
        PopupMenuItem(
          value: 'sources',
          child: ListTile(
            leading: const Icon(Icons.source_outlined),
            title: Text(item.sources.isEmpty ? 'Fuentes' : 'Fuentes (${item.sources.length})'),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline_rounded, color: danger),
            title: Text('Borrar', style: TextStyle(color: danger)),
          ),
        ),
      ],
    );
  }
}
