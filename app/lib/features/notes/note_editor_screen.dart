import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';

/// Create/edit a single note. Edits autosave to the local database (which marks
/// the row dirty for the next sync). Controllers are seeded once from the note
/// so live DB updates don't reset the cursor.
class NoteEditorScreen extends ConsumerStatefulWidget {
  const NoteEditorScreen({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  bool _seeded = false;

  // Per-item text controllers for checklists, keyed by item id.
  final Map<String, TextEditingController> _itemCtrls = {};

  NotesRepository get _repo => ref.read(notesRepositoryProvider);

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    for (final c in _itemCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _seed(NoteRow note) {
    if (_seeded) return;
    _titleCtrl.text = note.title;
    _bodyCtrl.text = note.body;
    _seeded = true;
  }

  TextEditingController _itemCtrl(ChecklistItemRow item) {
    final existing = _itemCtrls[item.id];
    if (existing != null) return existing;
    final c = TextEditingController(text: item.content);
    _itemCtrls[item.id] = c;
    return c;
  }

  @override
  Widget build(BuildContext context) {
    final noteAsync = ref.watch(noteProvider(widget.noteId));

    return noteAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (note) {
        if (note == null || note.deleted) {
          // Note was deleted (possibly via sync); leave the editor.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const Scaffold(body: SizedBox.shrink());
        }
        _seed(note);

        return Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                tooltip: note.pinned ? 'Unpin' : 'Pin',
                icon: Icon(
                    note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                onPressed: () => _repo.setPinned(note.id, !note.pinned),
              ),
              IconButton(
                tooltip: note.archived ? 'Unarchive' : 'Archive',
                icon: Icon(note.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined),
                onPressed: () => _repo.setArchived(note.id, !note.archived),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await _repo.softDelete(note.id);
                  if (context.mounted) Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  hintText: 'Title',
                  border: InputBorder.none,
                ),
                style: Theme.of(context).textTheme.titleLarge,
                onChanged: (v) => _repo.updateNoteFields(note.id, title: v),
              ),
              const SizedBox(height: 8),
              if (note.type == 'checklist')
                _ChecklistEditor(
                  noteId: note.id,
                  controllerFor: _itemCtrl,
                  onForgetController: (id) => _itemCtrls.remove(id)?.dispose(),
                )
              else
                TextField(
                  controller: _bodyCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Note',
                    border: InputBorder.none,
                  ),
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  onChanged: (v) => _repo.updateNoteFields(note.id, body: v),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ChecklistEditor extends ConsumerWidget {
  const _ChecklistEditor({
    required this.noteId,
    required this.controllerFor,
    required this.onForgetController,
  });

  final String noteId;
  final TextEditingController Function(ChecklistItemRow) controllerFor;
  final void Function(String id) onForgetController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(notesRepositoryProvider);
    final itemsAsync = ref.watch(checklistItemsProvider(noteId));

    return itemsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Text('Error: $e'),
      data: (items) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final it in items)
              Row(
                key: ValueKey(it.id),
                children: [
                  Checkbox(
                    value: it.checked,
                    onChanged: (v) =>
                        repo.setItemChecked(it.id, v ?? false),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controllerFor(it),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'List item',
                      ),
                      style: it.checked
                          ? const TextStyle(
                              decoration: TextDecoration.lineThrough)
                          : null,
                      onChanged: (v) => repo.setItemContent(it.id, v),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove',
                    onPressed: () {
                      repo.deleteItem(it.id);
                      onForgetController(it.id);
                    },
                  ),
                ],
              ),
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
              onPressed: () => repo.addItem(noteId),
            ),
          ],
        );
      },
    );
  }
}
