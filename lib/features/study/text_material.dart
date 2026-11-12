import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/empty_state.dart';
import '../ai/citation_widgets.dart';
import '../ai/citations.dart';
import 'study_common.dart';
import 'study_models.dart';

/// Resumen, esquema o conceptos clave: Markdown con referencias [n] tocables.
class TextMaterialView extends StatelessWidget {
  const TextMaterialView({super.key, required this.item, required this.content, required this.onEdit});

  final StudyItem item;
  final TextContent content;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final detail = switch (content.detail) {
      'brief' => 'Breve',
      'detailed' => 'Detallado',
      _ => null,
    };
    final cited = citedNumbers(content.text).where(content.citationNumbers.contains).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xxl),
      children: [
        StudyMetaLine(item: item, extra: detail),
        const SizedBox(height: Insets.lg),
        if (content.text.trim().isEmpty)
          EmptyState(
            icon: Icons.notes_rounded,
            title: 'Este material está vacío',
            message: 'Puedes escribir el contenido a mano.',
            actionLabel: 'Editar',
            onAction: onEdit,
            compact: true,
          )
        else
          CitedMarkdown(text: content.text, citations: content.citations, selectable: true),
        if (cited.isNotEmpty) ...[
          const SizedBox(height: Insets.xl),
          Semantics(header: true, child: Text('Referencias', style: context.text.titleMedium)),
          const SizedBox(height: Insets.sm),
          CitationChips(citations: content.citations, numbers: cited),
        ],
        SourcesSection(sources: item.sources),
      ],
    );
  }
}

/// Editor del texto (Markdown) y del título.
class TextMaterialEditor extends ConsumerStatefulWidget {
  const TextMaterialEditor({super.key, required this.item, required this.content});

  final StudyItem item;
  final TextContent content;

  @override
  ConsumerState<TextMaterialEditor> createState() => _TextMaterialEditorState();
}

class _TextMaterialEditorState extends ConsumerState<TextMaterialEditor> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _body = TextEditingController(text: widget.content.text);
  bool _saving = false;

  bool get _dirty => _title.text != widget.item.title || _body.text != widget.content.text;

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _body.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      showValidation(context, 'Escribe un título');
      return;
    }
    setState(() => _saving = true);
    final ok = await saveStudyItem(
      context,
      ref,
      id: widget.item.id,
      title: _title.text,
      content: widget.content.copyWith(text: _body.text),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return EditorScaffold(
      title: 'Editar',
      dirty: _dirty,
      saving: _saving,
      onSave: _dirty ? _save : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xxl),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            style: context.text.titleLarge,
            decoration: const InputDecoration(labelText: 'Título'),
          ),
          const SizedBox(height: Insets.md),
          TextField(
            controller: _body,
            minLines: 12,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            style: context.text.bodyLarge,
            decoration: const InputDecoration(
              labelText: 'Contenido',
              alignLabelWithHint: true,
              helperText: 'Admite Markdown. Conserva las referencias [n] para mantener los enlaces a tus fuentes.',
              helperMaxLines: 3,
            ),
          ),
        ],
      ),
    );
  }
}
