import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../src/rust/api/types.dart';

/// Atajos de navegación compartidos entre funcionalidades.
extension FolioNavigation on BuildContext {
  Future<void> openFolder(String folderId) => push('/folder/$folderId');

  /// Abre una nota de texto o una pizarra. `highlight` resalta y desplaza al primer resultado;
  /// `blockId` desplaza a un bloque concreto (referencias de la IA).
  Future<void> openNote(String noteId, {NoteKind kind = NoteKind.text, String? highlight, String? blockId}) {
    if (kind == NoteKind.board) return push('/board/$noteId');
    final q = <String, String>{
      if (highlight != null && highlight.isNotEmpty) 'highlight': highlight,
      'block': ?blockId,
    };
    return push(Uri(path: '/note/$noteId', queryParameters: q.isEmpty ? null : q).toString());
  }

  /// Abre el visor de un adjunto (imagen o PDF) en una página, opcionalmente resaltando texto.
  Future<void> openAttachment(String attachmentId, {int? page, String? highlight}) {
    final q = <String, String>{
      if (page != null) 'page': '$page',
      if (highlight != null && highlight.isNotEmpty) 'highlight': highlight,
    };
    return push(Uri(path: '/attachment/$attachmentId', queryParameters: q.isEmpty ? null : q).toString());
  }

  /// Navega a la fuente de una cita de la IA (página de adjunto o bloque de nota).
  Future<void> openCitation(Citation c) {
    final snippet = c.snippet.length > 60 ? c.snippet.substring(0, 60) : c.snippet;
    if (c.pageId != null && c.blockId == null) {
      return push(Uri(path: '/note/${c.noteId}', queryParameters: {'highlight': snippet}).toString());
    }
    return openNote(c.noteId, blockId: c.blockId, highlight: snippet);
  }

  /// Abre una conversación nueva sobre un ámbito.
  Future<void> openNewChat(AiScope scope, {String? question}) => push(
    Uri(path: '/chat/new', queryParameters: question == null ? null : {'q': question}).toString(),
    extra: scope,
  );
}

/// Constructores cómodos de ámbitos de IA / búsqueda.
abstract final class Scopes {
  static AiScope note(String id) => AiScope(kind: ScopeKind.note, ids: [id]);
  static AiScope notes(List<String> ids) => AiScope(kind: ScopeKind.notes, ids: ids);
  static AiScope folder(String id) => AiScope(kind: ScopeKind.folder, ids: [id]);
  static const library = AiScope(kind: ScopeKind.library_, ids: []);

  static const searchLibrary = SearchScope(kind: SearchScopeKind.library_);
  static SearchScope searchFolder(String id) => SearchScope(kind: SearchScopeKind.folder, id: id);
  static SearchScope searchNote(String id) => SearchScope(kind: SearchScopeKind.note, id: id);
}
