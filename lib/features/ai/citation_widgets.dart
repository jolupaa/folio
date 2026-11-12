import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../core/navigation.dart';
import '../../src/rust/api/types.dart';
import '../study/study_models.dart' show findCitation;
import 'citations.dart';

/// Hoja con el detalle de una referencia [n]: nota, ubicación, página y fragmento, con
/// «Abrir fuente». Si la cita no existe o su fuente se borró, lo indica.
Future<void> showCitationSheet(BuildContext context, {required int n, Citation? citation}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _CitationSheet(
      n: n,
      citation: citation,
      onOpen: citation == null || !citation.exists
          ? null
          : () {
              Navigator.pop(sheetContext);
              if (context.mounted) context.openCitation(citation);
            },
    ),
  );
}

/// Texto de página/adjunto de una cita: «Página 3 · apuntes.pdf», o null si no aplica.
String? citationPageLabel(Citation c) {
  final parts = <String>[
    if (c.pageIndex != null) 'Página ${c.pageIndex! + 1}',
    if (c.attachmentName != null && c.attachmentName!.isNotEmpty) c.attachmentName!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String citationTitle(Citation c) => c.noteTitle.trim().isEmpty ? 'Nota sin título' : c.noteTitle.trim();

class _CitationSheet extends StatelessWidget {
  const _CitationSheet({required this.n, required this.citation, required this.onOpen});

  final int n;
  final Citation? citation;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cit = citation;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Insets.gutter, 0, Insets.gutter, Insets.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(header: true, child: Text('Referencia [$n]', style: context.text.labelMedium)),
            const SizedBox(height: Insets.sm),
            if (cit == null) ...[
              Text('Fuente no disponible', style: context.text.titleMedium),
              const SizedBox(height: Insets.xs),
              Text(
                'Esta referencia no corresponde a ningún fragmento guardado.',
                style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
              ),
            ] else ...[
              Text(citationTitle(cit), style: context.text.titleLarge),
              if (!cit.exists) ...[const SizedBox(height: Insets.sm), const DeletedSourceBadge()],
              const SizedBox(height: Insets.sm),
              _MetaRow(icon: Icons.folder_outlined, text: Fmt.location(cit.location)),
              if (citationPageLabel(cit) case final page?) _MetaRow(icon: Icons.insert_drive_file_outlined, text: page),
              if (cit.snippet.trim().isNotEmpty) ...[
                const SizedBox(height: Insets.md),
                Container(
                  padding: const EdgeInsets.all(Insets.md),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(Insets.radiusGroup),
                    border: Border(left: BorderSide(color: c.accent, width: 3)),
                  ),
                  child: SelectableText(cit.snippet.trim(), style: context.text.bodyMedium),
                ),
              ],
              const SizedBox(height: Insets.lg),
              FilledButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(cit.exists ? 'Abrir fuente' : 'La fuente se eliminó'),
              ),
              const SizedBox(height: Insets.sm),
              TextButton.icon(
                onPressed: cit.snippet.trim().isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: cit.snippet.trim()));
                        ScaffoldMessenger.maybeOf(context)
                            ?.showSnackBar(const SnackBar(content: Text('Fragmento copiado')));
                      },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copiar fragmento'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Insets.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: context.colors.textSecondary),
        const SizedBox(width: Insets.sm),
        Expanded(child: Text(text, style: context.text.bodySmall)),
      ],
    ),
  );
}

/// Marca «Fuente eliminada» (icono + texto: no depende solo del color).
class DeletedSourceBadge extends StatelessWidget {
  const DeletedSourceBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.link_off_rounded, size: 16, color: c.danger),
        const SizedBox(width: Insets.xs),
        Text('Fuente eliminada', style: context.text.labelSmall?.copyWith(color: c.danger)),
      ],
    );
  }
}

/// Fila de chips con las fuentes citadas («[1] Tema 2»). Las fuentes borradas aparecen tachadas
/// con la indicación «fuente eliminada».
class CitationChips extends StatelessWidget {
  const CitationChips({super.key, required this.citations, this.numbers});

  final List<Citation> citations;

  /// Números a mostrar (en orden). Null = todas las citas.
  final List<int>? numbers;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final shown = numbers ?? [for (final x in citations) x.n];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Insets.sm,
      runSpacing: 0,
      children: [
        for (final n in shown)
          Builder(
            builder: (context) {
              final cit = findCitation(citations, n);
              final deleted = cit == null || !cit.exists;
              final title = cit == null ? 'No disponible' : citationTitle(cit);
              return Semantics(
                button: true,
                label: 'Referencia $n: $title${deleted ? ', fuente eliminada' : ''}',
                excludeSemantics: true,
                child: ActionChip(
                  avatar: Text(
                    '$n',
                    style: context.text.labelSmall?.copyWith(
                      color: deleted ? c.textSecondary : c.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      deleted && cit != null ? '$title · fuente eliminada' : title,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.labelMedium?.copyWith(
                        color: deleted ? c.textSecondary : c.textPrimary,
                        decoration: deleted ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                  onPressed: () => showCitationSheet(context, n: n, citation: cit),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Hoja de estilo Markdown con los tokens de Folio.
MarkdownStyleSheet folioMarkdownStyle(BuildContext context, {TextStyle? base}) {
  final theme = Theme.of(context);
  final c = context.colors;
  final body = base ?? context.text.bodyLarge;
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    listBullet: body,
    a: TextStyle(color: c.accent, fontWeight: FontWeight.w700),
    h1: context.text.titleLarge,
    h2: context.text.titleMedium?.copyWith(fontSize: 19),
    h3: context.text.titleMedium,
    h4: context.text.titleSmall,
    strong: const TextStyle(fontWeight: FontWeight.w700),
    blockquote: body?.copyWith(color: c.textSecondary),
    blockquoteDecoration: BoxDecoration(
      color: c.surfaceAlt,
      borderRadius: BorderRadius.circular(8),
      border: Border(left: BorderSide(color: c.accent, width: 3)),
    ),
    code: context.text.bodyMedium?.copyWith(fontFamily: 'monospace', backgroundColor: c.surfaceAlt),
    codeblockDecoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(8)),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: c.separator)),
    ),
    tableBorder: TableBorder.all(color: c.separator),
    blockSpacing: Insets.md,
  );
}

/// Markdown con referencias [n] convertidas en enlaces que abren la hoja de la cita.
class CitedMarkdown extends StatelessWidget {
  const CitedMarkdown({super.key, required this.text, required this.citations, this.selectable = false, this.style});

  final String text;
  final List<Citation> citations;
  final bool selectable;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final known = {for (final c in citations) c.n};
    return MarkdownBody(
      data: linkCitationsInMarkdown(text, known: known),
      selectable: selectable,
      styleSheet: folioMarkdownStyle(context, base: style),
      softLineBreak: true,
      onTapLink: (linkText, href, title) {
        final n = citationFromHref(href);
        if (n != null) showCitationSheet(context, n: n, citation: findCitation(citations, n));
      },
    );
  }
}
