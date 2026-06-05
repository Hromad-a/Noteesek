import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import 'note_card.dart';
import 'note_editor_screen.dart';

/// Home screen: a Keep-style masonry grid of notes with a create FAB.
class NotesScreen extends ConsumerWidget {
  const NotesScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref, String type) async {
    final id = await ref.read(notesRepositoryProvider).createNote(type: type);
    if (type == 'checklist') {
      await ref.read(notesRepositoryProvider).addItem(id);
    }
    if (context.mounted) _open(context, id);
  }

  void _open(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: id)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(activeNotesProvider);
    final pb = ref.watch(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';
    final sync = ref.watch(syncControllerProvider);

    // Surface sync errors unobtrusively.
    ref.listen(syncControllerProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: ${next.error}')),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        actions: [
          if (sync.syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Sync now',
              icon: const Icon(Icons.sync),
              onPressed: () =>
                  ref.read(syncControllerProvider.notifier).syncNow(),
            ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) {
              if (v == 'logout') pb.authStore.clear();
            },
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(email)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (notes) {
          if (notes.isEmpty) return const _EmptyState();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: MasonryGridView.extent(
                maxCrossAxisExtent: 240,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                itemCount: notes.length,
                itemBuilder: (context, i) {
                  final NoteRow note = notes[i];
                  return NoteCard(note: note, onTap: () => _open(context, note.id));
                },
              ),
            ),
          );
        },
      ),
      floatingActionButton: _CreateFab(
        onText: () => _create(context, ref, 'text'),
        onChecklist: () => _create(context, ref, 'checklist'),
      ),
    );
  }
}

class _CreateFab extends StatelessWidget {
  const _CreateFab({required this.onText, required this.onChecklist});

  final VoidCallback onText;
  final VoidCallback onChecklist;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'fab-checklist',
          tooltip: 'New checklist',
          onPressed: onChecklist,
          child: const Icon(Icons.checklist),
        ),
        const SizedBox(width: 12),
        FloatingActionButton(
          heroTag: 'fab-text',
          tooltip: 'New note',
          onPressed: onText,
          child: const Icon(Icons.edit),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lightbulb_outline,
              size: 72, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          const Text('Notes you add appear here'),
        ],
      ),
    );
  }
}
