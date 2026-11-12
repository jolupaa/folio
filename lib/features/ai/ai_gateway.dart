import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/ai.dart' as ai;
import '../../src/rust/api/library.dart' as lib;
import '../../src/rust/api/types.dart';

/// Acceso a la API de IA de Rust (y a las consultas de biblioteca que necesita la UI de IA).
/// Se inyecta con [aiGatewayProvider] para poder sustituirlo en pruebas.
abstract interface class AiGateway {
  Future<ScopeSummary> describeScope(AiScope scope);
  Stream<AiEvent> ask({required AiScope scope, required String question, String? threadId});
  Stream<AiEvent> generateStudy({required StudyKind kind, required AiScope scope, required StudyOptions options});
  Stream<AiEvent> gradeOpenAnswer({required String studyId, required String questionId, required String response});
  bool cancelTask(String taskId);
  Future<List<ChatThreadSummary>> listThreads();
  Future<ChatThread> getThread(String threadId);
  Future<void> renameThread(String threadId, String title);
  Future<void> deleteThread(String threadId);

  /// Todas las notas no borradas (selector de fuentes).
  Future<List<NoteSummary>> listAllNotes();
  Future<List<Folder>> listFolders();

  /// Carpeta de una nota (null = bandeja «Notas»).
  Future<String?> noteFolderId(String noteId);
}

class FrbAiGateway implements AiGateway {
  const FrbAiGateway();

  @override
  Future<ScopeSummary> describeScope(AiScope scope) => ai.describeScope(scope: scope);

  @override
  Stream<AiEvent> ask({required AiScope scope, required String question, String? threadId}) =>
      ai.ask(scope: scope, question: question, threadId: threadId);

  @override
  Stream<AiEvent> generateStudy({required StudyKind kind, required AiScope scope, required StudyOptions options}) =>
      ai.generateStudy(kind: kind, scope: scope, options: options);

  @override
  Stream<AiEvent> gradeOpenAnswer({required String studyId, required String questionId, required String response}) =>
      ai.gradeOpenAnswer(studyId: studyId, questionId: questionId, response: response);

  @override
  bool cancelTask(String taskId) => ai.cancelTask(taskId: taskId);

  @override
  Future<List<ChatThreadSummary>> listThreads() => ai.listThreads();

  @override
  Future<ChatThread> getThread(String threadId) => ai.getThread(threadId: threadId);

  @override
  Future<void> renameThread(String threadId, String title) => ai.renameThread(threadId: threadId, title: title);

  @override
  Future<void> deleteThread(String threadId) => ai.deleteThread(threadId: threadId);

  @override
  Future<List<NoteSummary>> listAllNotes() => lib.listNotes(scope: NoteListScope.all);

  @override
  Future<List<Folder>> listFolders() => lib.listFolders();

  @override
  Future<String?> noteFolderId(String noteId) async => (await lib.getNote(id: noteId)).folderId;
}

final aiGatewayProvider = Provider<AiGateway>((ref) => const FrbAiGateway());

/// Sin reintentos automáticos: los errores se muestran con un botón «Reintentar».
Duration? noAutoRetry(int retryCount, Object error) => null;

/// Contador de cambios en conversaciones (crear, renombrar, borrar).
class ThreadsRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final threadsRevisionProvider = NotifierProvider<ThreadsRevision, int>(ThreadsRevision.new);

final threadsProvider = FutureProvider<List<ChatThreadSummary>>((ref) {
  ref.watch(threadsRevisionProvider);
  return ref.watch(aiGatewayProvider).listThreads();
}, retry: noAutoRetry);
