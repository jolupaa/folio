import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/app.dart' as app_api;
import '../../src/rust/api/attachments.dart' as attachments_api;
import '../../src/rust/api/boards.dart' as boards_api;
import '../../src/rust/api/types.dart';

/// Acceso a datos de la pizarra. Se inyecta con [boardRepositoryProvider] para poder
/// sustituirlo en pruebas.
abstract interface class BoardRepository {
  Future<Board> load(String noteId);

  /// Guarda título y escena; Rust deriva el texto de los elementos `text` para búsqueda e IA.
  Future<void> save(String noteId, String title, String sceneJson);

  /// Importa una imagen como adjunto de la pizarra (`note_id` = id de la pizarra).
  Future<Attachment> importImage(String noteId, String sourcePath, String fileName);

  /// Ruta absoluta del fichero de un adjunto.
  Future<String> attachmentPath(String attachmentId);

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
}

class RustBoardRepository implements BoardRepository {
  const RustBoardRepository();

  @override
  Future<Board> load(String noteId) => boards_api.getBoard(noteId: noteId);

  @override
  Future<void> save(String noteId, String title, String sceneJson) =>
      boards_api.saveBoard(noteId: noteId, title: title, sceneJson: sceneJson);

  @override
  Future<Attachment> importImage(String noteId, String sourcePath, String fileName) =>
      attachments_api.importImage(noteId: noteId, sourcePath: sourcePath, fileName: fileName);

  @override
  Future<String> attachmentPath(String attachmentId) async =>
      (await attachments_api.getAttachment(id: attachmentId)).path;

  @override
  Future<String?> getSetting(String key) => app_api.getSetting(key: key);

  @override
  Future<void> setSetting(String key, String value) => app_api.setSetting(key: key, value: value);
}

final boardRepositoryProvider = Provider<BoardRepository>((ref) => const RustBoardRepository());
