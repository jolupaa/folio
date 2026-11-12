import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../src/rust/api/types.dart';
import 'ai_actions_sheet.dart';
import 'generation_sheet.dart';

/// Punto de entrada único a las acciones de IA (hoja compacta). Lo usan la nota, la carpeta y la
/// biblioteca. `selectedText` permite «Explicar» un fragmento seleccionado.
///
/// Preguntar abre una conversación (`/chat/new`); los materiales se generan en una hoja de
/// progreso y al terminar se abre `/study/<id>`.
Future<void> showAiActions(BuildContext context, {required AiScope scope, String? selectedText}) async {
  // El router se captura antes: el contexto de origen podría desmontarse mientras la hoja está abierta.
  final router = GoRouter.maybeOf(context);
  final result = await showModalBottomSheet<AiSheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AiActionsSheet(scope: scope, selectedText: selectedText),
  );
  if (result == null) return;
  switch (result) {
    case AskResult(:final scope, :final question):
      router?.push(
        Uri(path: '/chat/new', queryParameters: {'q': question}).toString(),
        extra: scope,
      );
    case OpenModelsResult():
      router?.push('/settings/models');
    case StudyResult(:final request):
      final host = context.mounted ? context : router?.routerDelegate.navigatorKey.currentContext;
      if (host == null || !host.mounted) return;
      await runStudyGeneration(host, request, router: router);
  }
}

/// Genera un material mostrando el progreso y, al terminar, abre `/study/<id>`.
Future<void> runStudyGeneration(BuildContext context, StudyRequest request, {GoRouter? router}) async {
  final nav = router ?? GoRouter.maybeOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await showGenerationSheet(context, request);
  switch (outcome) {
    case GenerationDone(:final studyId):
      nav?.push('/study/$studyId');
    case GenerationCancelled():
      messenger?.showSnackBar(const SnackBar(content: Text('Generación cancelada')));
    case null:
      break;
  }
}
