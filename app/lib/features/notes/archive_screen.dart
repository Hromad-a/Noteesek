import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import 'note_card.dart';
import 'note_editor_screen.dart';

/// Lists archived notes. Each card's archive button unarchives it (which then
/// removes it from this list and returns it to the main grid).
class ArchiveScreen extends ConsumerWidget {
  const ArchiveScreen({super.key});

  void _open(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: id)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(archivedNotesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.archive)),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(context.l10n.errorWithDetail('$e'))),
        data: (notes) {
          if (notes.isEmpty) return const _EmptyArchive();
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
                  return NoteCard(
                    note: note,
                    onTap: () => _open(context, note.id),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyArchive extends StatelessWidget {
  const _EmptyArchive();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.archive_outlined,
              size: 64, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(context.l10n.noArchivedNotes),
        ],
      ),
    );
  }
}
