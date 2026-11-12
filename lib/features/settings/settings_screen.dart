import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme_mode.dart';
import '../../src/rust/api/ai.dart' as ai;
import '../../src/rust/api/app.dart' as app;
import '../../src/rust/api/types.dart';
import '../../widgets/grouped_section.dart';
import '../library/library_tiles.dart';

final storageInfoProvider = FutureProvider.autoDispose<StorageInfo>((ref) {
  ref.watch(libraryRevisionProvider);
  return app.storageInfo();
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(storageInfoProvider).value;
    final status = ref.watch(aiStatusProvider).value;
    final index = ref.watch(indexStatusProvider).value;
    final c = context.colors;
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;

    Widget info(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
      child: Row(
        children: [
          Expanded(child: Text(label, style: context.text.bodyLarge)),
          const SizedBox(width: Insets.md),
          Text(value, style: context.text.bodyMedium?.copyWith(color: c.textSecondary)),
        ],
      ),
    );
    Widget paragraph(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
      child: Text(text, style: context.text.bodyMedium),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          GroupedSection(
            header: 'Apariencia',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, label: Text('Sistema')),
                      ButtonSegment(value: ThemeMode.light, label: Text('Claro')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Oscuro')),
                    ],
                    selected: {ref.watch(themeModeProvider)},
                    onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
                  ),
                ),
              ),
            ],
          ),
          GroupedSection(
            header: 'Inteligencia artificial',
            footer: status == null
                ? null
                : status.llmInstalled
                ? (status.unavailableReason ?? 'La IA funciona en este dispositivo, sin conexión.')
                : 'Sin modelo instalado: las notas, la búsqueda, el OCR y la pizarra funcionan igual.',
            children: [
              LibraryRow(
                icon: Icons.auto_awesome_rounded,
                title: 'Modelos de IA',
                onTap: () => context.push('/settings/models'),
              ),
              if (index != null)
                info(
                  'Índice para la IA',
                  index.pendingNotes > 0
                      ? 'Indexando · quedan ${Fmt.count(index.pendingNotes, 'nota', 'notas')}'
                      : index.embeddingModelId == null
                      ? '${index.chunkCount} fragmentos (solo texto)'
                      : '${index.embeddedChunkCount} de ${index.chunkCount} fragmentos',
                ),
              LibraryRow(
                icon: Icons.refresh_rounded,
                title: 'Reconstruir el índice',
                onTap: () async {
                  await ai.reindexAll();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Reconstruyendo el índice en segundo plano')),
                    );
                  }
                },
              ),
            ],
          ),
          GroupedSection(
            header: 'Almacenamiento',
            children: [
              info('Notas (base de datos)', storage == null ? '…' : Fmt.bytes(storage.databaseBytes)),
              info('Adjuntos', storage == null ? '…' : Fmt.bytes(storage.filesBytes)),
              info('Modelos de IA', storage == null ? '…' : Fmt.bytes(storage.modelsBytes)),
              info('Libre en el dispositivo', storage == null ? '…' : Fmt.bytes(storage.freeBytes)),
            ],
          ),
          GroupedSection(
            header: 'Privacidad',
            children: [
              paragraph(
                'Tus notas, imágenes y preguntas se guardan y se procesan en este dispositivo. '
                'Solo se usa la conexión para descargar los modelos de IA; después todo funciona sin conexión.',
              ),
              paragraph(
                isAndroid
                    ? 'El reconocimiento de texto usa Google ML Kit, incluido en la app. Las imágenes y el texto no salen '
                          'del dispositivo, pero la librería puede enviar a Google métricas de uso anónimas.'
                    : 'El reconocimiento de texto usa Apple Vision y se ejecuta en el dispositivo.',
              ),
              paragraph(
                'El OCR reconoce bien texto impreso. La escritura a mano, las fórmulas y los diagramas pueden '
                'reconocerse mal o no reconocerse: revisa siempre el resultado.',
              ),
            ],
          ),
          GroupedSection(
            header: 'Acerca de',
            children: [
              info('Versión', '1.0.0'),
              LibraryRow(
                icon: Icons.description_outlined,
                title: 'Licencias de código abierto',
                onTap: () =>
                    showLicensePage(context: context, applicationName: 'Folio', applicationVersion: '1.0.0'),
              ),
            ],
          ),
          const SizedBox(height: Insets.xl),
        ],
      ),
    );
  }
}
