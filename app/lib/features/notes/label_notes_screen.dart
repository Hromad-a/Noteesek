import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../data/notes_repository.dart';
import 'note_card.dart';
import 'note_editor_screen.dart';

/// A read-only masonry grid of the active notes carrying a given label.
class LabelNotesScreen extends ConsumerWidget {
  const LabelNotesScreen({
    super.key,
    required this.labelId,
    required this.labelName,
  });

  final String labelId;
  final String labelName;

  void _open(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: id)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(notesByLabelProvider(labelId));

    return Scaffold(
      appBar: AppBar(title: Text(labelName)),
      body: notesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (notes) {
          if (notes.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.label_outline,
                      size: 56, color: Theme.of(context).disabledColor),
                  const SizedBox(height: 8),
                  const Text('No notes with this label'),
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(8),
            child: MasonryGridView.extent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              itemCount: notes.length,
              itemBuilder: (context, i) {
                final note = notes[i];
                return NoteCard(
                  note: note,
                  onTap: () => _open(context, note.id),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
