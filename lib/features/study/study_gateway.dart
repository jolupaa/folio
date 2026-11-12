import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/study.dart' as study;
import '../../src/rust/api/types.dart';
import '../ai/ai_gateway.dart' show noAutoRetry;

/// Acceso a la API de materiales de estudio de Rust. Sustituible en pruebas con
/// [studyGatewayProvider].
abstract interface class StudyGateway {
  Future<List<StudyItemSummary>> listItems({String? noteId});
  Future<StudyItem> getItem(String id);
  Future<StudyItem> updateItem(String id, {required String title, required String contentJson});
  Future<void> deleteItem(String id);
  Future<QuizAttempt> saveQuizAttempt(
    String studyId, {
    required String answersJson,
    double? score,
    required bool completed,
  });
  Future<List<QuizAttempt>> listQuizAttempts(String studyId);
}

class FrbStudyGateway implements StudyGateway {
  const FrbStudyGateway();

  @override
  Future<List<StudyItemSummary>> listItems({String? noteId}) => study.listStudyItems(noteId: noteId);

  @override
  Future<StudyItem> getItem(String id) => study.getStudyItem(id: id);

  @override
  Future<StudyItem> updateItem(String id, {required String title, required String contentJson}) =>
      study.updateStudyItem(id: id, title: title, contentJson: contentJson);

  @override
  Future<void> deleteItem(String id) => study.deleteStudyItem(id: id);

  @override
  Future<QuizAttempt> saveQuizAttempt(
    String studyId, {
    required String answersJson,
    double? score,
    required bool completed,
  }) => study.saveQuizAttempt(studyId: studyId, answersJson: answersJson, score: score, completed: completed);

  @override
  Future<List<QuizAttempt>> listQuizAttempts(String studyId) => study.listQuizAttempts(studyId: studyId);
}

final studyGatewayProvider = Provider<StudyGateway>((ref) => const FrbStudyGateway());

/// Contador de cambios en materiales de estudio (generar, editar, borrar, guardar intentos).
class StudyRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final studyRevisionProvider = NotifierProvider<StudyRevision, int>(StudyRevision.new);

final studyItemsProvider = FutureProvider<List<StudyItemSummary>>((ref) {
  ref.watch(studyRevisionProvider);
  return ref.watch(studyGatewayProvider).listItems();
}, retry: noAutoRetry);

final studyItemProvider = FutureProvider.autoDispose.family<StudyItem, String>((ref, id) {
  ref.watch(studyRevisionProvider);
  return ref.watch(studyGatewayProvider).getItem(id);
}, retry: noAutoRetry);

final quizAttemptsProvider = FutureProvider.autoDispose.family<List<QuizAttempt>, String>((ref, studyId) {
  ref.watch(studyRevisionProvider);
  return ref.watch(studyGatewayProvider).listQuizAttempts(studyId);
}, retry: noAutoRetry);
