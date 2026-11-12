import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lifecycle.dart';
import '../core/theme_mode.dart';
import 'router.dart';
import 'theme.dart';

class FolioApp extends ConsumerStatefulWidget {
  const FolioApp({super.key, this.startupError});

  /// Error al abrir la base de datos / inicializar Rust: se muestra una pantalla de error.
  final Object? startupError;

  @override
  ConsumerState<FolioApp> createState() => _FolioAppState();
}

class _FolioAppState extends ConsumerState<FolioApp> {
  late final AiMemoryLifecycle _lifecycle = AiMemoryLifecycle();

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const locale = Locale('es');
    const delegates = [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      FlutterQuillLocalizations.delegate,
    ];
    if (widget.startupError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        supportedLocales: const [locale],
        localizationsDelegates: delegates,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: _StartupErrorScreen(error: widget.startupError!),
      );
    }
    return MaterialApp.router(
      title: 'Folio',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: const [locale, Locale('en')],
      localizationsDelegates: delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: context.colors.danger),
              const SizedBox(height: Insets.lg),
              Text('No se pudo abrir la biblioteca', style: context.text.headlineSmall),
              const SizedBox(height: Insets.sm),
              Text(
                'Tus notas no se han modificado. Cierra la app y vuelve a abrirla; si el problema '
                'continúa, comprueba que queda espacio libre en el dispositivo.',
                style: context.text.bodyMedium,
              ),
              const SizedBox(height: Insets.lg),
              SelectableText('$error', style: context.text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
