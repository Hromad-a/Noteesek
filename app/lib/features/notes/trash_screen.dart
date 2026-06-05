import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../sync/sync_controller.dart';

/// Trash: soft-deleted notes that haven't been purged. Restore, delete forever,
/// or empty the whole trash. Purge is manual only (no auto-delete).
class TrashScreen extends ConsumerWidget {
  const TrashScreen({super.key});

  Future<void> _deleteForever(WidgetRef ref, String noteId) async {
    // Remove on the server first (best-effort), then purge locally.
    await ref.read(syncEngineProvider).deleteNoteRemote(noteId);
    await ref.read(notesRepositoryProvider).purgeLocal(noteId);
  }

  Future<void> _emptyTrash(WidgetRef ref) async {
    final repo = ref.read(notesRepositoryProvider);
    final ids = await repo.trashedNoteIds();
    for (final id in ids) {
      await _deleteForever(ref, id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(trashedNotesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          notesAsync.maybeWhen(
            data: (notes) => notes.isEmpty
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () async {
                      final ok = await _confirm(
                        context,
                        title: 'Empty trash?',
                        message:
                            'Permanently delete all ${notes.length} notes in '
                            'trash. This cannot be undone.',
                        action: 'Empty trash',
                      );
                      if (ok) await _emptyTrash(ref);
                    },
                    child: const Text('Empty'),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (notes) {
          if (notes.isEmpty) return const _EmptyTrash();
          return SafeArea(
            child: ListView.separated(
              itemCount: notes.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final NoteRow note = notes[i];
                final title = note.title.trim().isNotEmpty
                    ? note.title
                    : (note.body.trim().isNotEmpty ? note.body : 'Empty note');
                return ListTile(
                  leading: Icon(note.type == 'checklist'
                      ? Icons.checklist
                      : Icons.notes),
                  title: Text(title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Restore',
                        icon: const Icon(Icons.restore_from_trash),
                        onPressed: () =>
                            ref.read(notesRepositoryProvider).restore(note.id),
                      ),
                      IconButton(
                        tooltip: 'Delete forever',
                        icon: const Icon(Icons.delete_forever),
                        onPressed: () async {
                          final ok = await _confirm(
                            context,
                            title: 'Delete forever?',
                            message:
                                'Permanently delete this note. This cannot be '
                                'undone.',
                            action: 'Delete',
                          );
                          if (ok) await _deleteForever(ref, note.id);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return res ?? false;
  }
}

class _EmptyTrash extends StatelessWidget {
  const _EmptyTrash();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline,
              size: 64, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          const Text('Trash is empty'),
        ],
      ),
    );
  }
}
