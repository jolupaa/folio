import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../src/rust/api/types.dart';
import '../../widgets/empty_state.dart';
import 'ai_gateway.dart';
import 'skeleton.dart';

/// Abre el selector de fuentes y devuelve los ids de notas elegidos (null si se cancela).
Future<List<String>?> pickSources(BuildContext context, {Iterable<String> initial = const []}) {
  return Navigator.of(context).push<List<String>>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => SourcePickerScreen(initial: initial.toSet())),
  );
}

/// Datos del selector: todas las notas (`list_notes(all)`) y la ruta de carpetas de cada una.
typedef SourcePickerData = ({List<NoteSummary> notes, Map<String, String> locations});

final sourcePickerDataProvider = FutureProvider.autoDispose<SourcePickerData>((ref) async {
  final gw = ref.watch(aiGatewayProvider);
  final results = await Future.wait([gw.listAllNotes(), gw.listFolders()]);
  final notes = results[0] as List<NoteSummary>;
  final folders = results[1] as List<Folder>;
  final byId = {for (final f in folders) f.id: f};
  final cache = <String, String>{};
  String locationOf(String? folderId) {
    if (folderId == null) return Fmt.location(const []);
    final cached = cache[folderId];
    if (cached != null) return cached;
    final names = <String>[];
    final seen = <String>{};
    String? cur = folderId;
    while (cur != null && seen.add(cur)) {
      final f = byId[cur];
      if (f == null) break;
      names.insert(0, f.name);
      cur = f.parentId;
    }
    return cache[folderId] = Fmt.location(names);
  }

  return (notes: notes, locations: {for (final n in notes) n.id: locationOf(n.folderId)});
}, retry: noAutoRetry);

/// Selector multi-nota para el ámbito «Elegir fuentes…».
class SourcePickerScreen extends ConsumerStatefulWidget {
  const SourcePickerScreen({super.key, this.initial = const {}});

  final Set<String> initial;

  @override
  ConsumerState<SourcePickerScreen> createState() => _SourcePickerScreenState();
}

class _SourcePickerScreenState extends ConsumerState<SourcePickerScreen> {
  late final Set<String> _selected = {...widget.initial};
  final _query = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String _title(NoteSummary n) => n.title.trim().isEmpty ? 'Nota sin título' : n.title.trim();

  bool _matches(NoteSummary n, String location) {
    if (_filter.isEmpty) return true;
    final q = _normalize(_filter);
    return _normalize(n.title).contains(q) || _normalize(n.preview).contains(q) || _normalize(location).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(sourcePickerDataProvider);
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Elegir fuentes'),
        leading: IconButton(
          tooltip: 'Cancelar',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected.toList()),
            child: Text(_selected.isEmpty ? 'Listo' : 'Listo (${_selected.length})'),
          ),
        ],
      ),
      body: data.when(
        loading: () => const SkeletonList(rows: 8, label: 'Cargando notas'),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'No se pudieron cargar las notas',
          message: humanError(e),
          actionLabel: 'Reintentar',
          onAction: () => ref.invalidate(sourcePickerDataProvider),
        ),
        data: (d) {
          if (d.notes.isEmpty) {
            return const EmptyState(
              icon: Icons.note_alt_outlined,
              title: 'No hay notas',
              message: 'Crea o importa notas para usarlas como fuentes de la IA.',
            );
          }
          final visible = [
            for (final n in d.notes)
              if (_matches(n, d.locations[n.id] ?? '')) n,
          ];
          final allVisibleSelected = visible.isNotEmpty && visible.every((n) => _selected.contains(n.id));
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Insets.gutter, Insets.sm, Insets.gutter, Insets.xs),
                child: TextField(
                  controller: _query,
                  onChanged: (v) => setState(() => _filter = v.trim()),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Filtrar notas',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _filter.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Borrar filtro',
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () => setState(() {
                              _query.clear();
                              _filter = '';
                            }),
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.gutter),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selected.isEmpty
                            ? 'Elige una o varias notas'
                            : Fmt.count(_selected.length, 'nota elegida', 'notas elegidas'),
                        style: context.text.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: visible.isEmpty
                          ? null
                          : () => setState(() {
                              if (allVisibleSelected) {
                                _selected.removeAll(visible.map((n) => n.id));
                              } else {
                                _selected.addAll(visible.map((n) => n.id));
                              }
                            }),
                      child: Text(allVisibleSelected ? 'Quitar todas' : 'Elegir todas'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? const EmptyState(icon: Icons.search_off_rounded, title: 'Sin coincidencias', compact: true)
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: Insets.xl),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => Divider(indent: 72, height: 0.6, color: c.separator),
                        itemBuilder: (context, i) {
                          final n = visible[i];
                          final selected = _selected.contains(n.id);
                          return CheckboxListTile(
                            value: selected,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(n.id);
                              } else {
                                _selected.remove(n.id);
                              }
                            }),
                            secondary: Icon(
                              n.kind == NoteKind.board ? Icons.draw_rounded : Icons.description_outlined,
                              color: c.textSecondary,
                            ),
                            title: Text(_title(n), maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(d.locations[n.id] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _normalize(String s) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñç';
  const to = 'aaaaeeeeiiiioooouuuunc';
  final lower = s.toLowerCase();
  final b = StringBuffer();
  for (final r in lower.runes) {
    final ch = String.fromCharCode(r);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}
