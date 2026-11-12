import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/ai/chat_screen.dart';
import '../features/attachments/attachment_screen.dart';
import '../features/board/board_screen.dart';
import '../features/capture/capture_flow.dart';
import '../features/library/folder_screen.dart';
import '../features/library/library_screen.dart';
import '../features/library/note_list_screen.dart';
import '../features/models/models_screen.dart';
import '../features/notes/note_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/study/study_item_screen.dart';
import '../features/study/study_list_screen.dart';
import '../features/trash/trash_screen.dart';
import '../src/rust/api/types.dart';

/// Rutas de la app (contrato de navegación; ver lib/core/navigation.dart para los atajos).
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (c, s) => const LibraryScreen()),
      GoRoute(
        path: '/notes/:scope',
        builder: (c, s) => NoteListScreen(
          scope: switch (s.pathParameters['scope']) {
            'pinned' => NoteListScope.pinned,
            'all' => NoteListScope.all,
            _ => NoteListScope.inbox,
          },
        ),
      ),
      GoRoute(
        path: '/folder/:id',
        builder: (c, s) => FolderScreen(folderId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/note/:id',
        builder: (c, s) => NoteScreen(
          noteId: s.pathParameters['id']!,
          highlight: s.uri.queryParameters['highlight'],
          blockId: s.uri.queryParameters['block'],
        ),
      ),
      GoRoute(
        path: '/board/:id',
        builder: (c, s) => BoardScreen(noteId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/capture',
        builder: (c, s) => CaptureFlowScreen(
          folderId: s.uri.queryParameters['folder'],
          appendToNoteId: s.uri.queryParameters['append'],
          source: CaptureSource.fromName(s.uri.queryParameters['source']),
        ),
      ),
      GoRoute(
        path: '/attachment/:id',
        builder: (c, s) => AttachmentScreen(
          attachmentId: s.pathParameters['id']!,
          page: int.tryParse(s.uri.queryParameters['page'] ?? ''),
          highlight: s.uri.queryParameters['highlight'],
        ),
      ),
      GoRoute(path: '/trash', builder: (c, s) => const TrashScreen()),
      GoRoute(path: '/study', builder: (c, s) => const StudyListScreen()),
      GoRoute(
        path: '/study/:id',
        builder: (c, s) => StudyItemScreen(studyId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (c, s) {
          final id = s.pathParameters['id']!;
          return ChatScreen(
            threadId: id == 'new' ? null : id,
            scope: s.extra is AiScope ? s.extra as AiScope : null,
            initialQuestion: s.uri.queryParameters['q'],
          );
        },
      ),
      GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen()),
      GoRoute(path: '/settings/models', builder: (c, s) => const ModelsScreen()),
    ],
  );
});
