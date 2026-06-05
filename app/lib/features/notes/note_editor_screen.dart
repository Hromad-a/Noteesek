import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';

enum _OverflowAction { archive, delete }

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

  Future<void> _pickImage(String noteId) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _repo.addAttachment(noteId, bytes);
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
                tooltip: 'Add image',
                icon: const Icon(Icons.image_outlined),
                onPressed: () => _pickImage(note.id),
              ),
              IconButton(
                tooltip: note.pinned ? 'Unpin' : 'Pin',
                icon: Icon(
                    note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                onPressed: () => _repo.setPinned(note.id, !note.pinned),
              ),
              PopupMenuButton<_OverflowAction>(
                onSelected: (action) async {
                  switch (action) {
                    case _OverflowAction.archive:
                      await _repo.setArchived(note.id, !note.archived);
                    case _OverflowAction.delete:
                      await _repo.softDelete(note.id);
                      if (context.mounted) Navigator.of(context).maybePop();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _OverflowAction.archive,
                    child: ListTile(
                      leading: Icon(note.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined),
                      title: Text(note.archived ? 'Unarchive' : 'Archive'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: _OverflowAction.delete,
                    child: const ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Delete'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
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
              _AttachmentsSection(noteId: note.id),
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

class _AttachmentsSection extends ConsumerWidget {
  const _AttachmentsSection({required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(notesRepositoryProvider);
    final async = ref.watch(attachmentsProvider(noteId));

    return async.maybeWhen(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in items)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 110,
                        height: 110,
                        child: a.data != null
                            ? Image.memory(a.data!, fit: BoxFit.cover)
                            : Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                child: const Icon(Icons.image_outlined),
                              ),
                      ),
                    ),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: IconButton(
                        icon: const Icon(Icons.cancel),
                        tooltip: 'Remove image',
                        color: Colors.black54,
                        onPressed: () => repo.deleteAttachment(a.id),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _ChecklistEditor extends ConsumerStatefulWidget {
  const _ChecklistEditor({
    required this.noteId,
    required this.controllerFor,
    required this.onForgetController,
  });

  final String noteId;
  final TextEditingController Function(ChecklistItemRow) controllerFor;
  final void Function(String id) onForgetController;

  @override
  ConsumerState<_ChecklistEditor> createState() => _ChecklistEditorState();
}

class _ChecklistEditorState extends ConsumerState<_ChecklistEditor> {
  final Map<String, FocusNode> _focusNodes = {};
  String? _pendingFocusId;

  FocusNode _focusNodeFor(String id) =>
      _focusNodes.putIfAbsent(id, () => FocusNode());

  @override
  void dispose() {
    for (final fn in _focusNodes.values) {
      fn.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(notesRepositoryProvider);
    final itemsAsync = ref.watch(checklistItemsProvider(widget.noteId));

    return itemsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Text('Error: $e'),
      data: (items) {
        // When a new item was just created via Enter, focus it once rendered.
        if (_pendingFocusId != null &&
            items.any((i) => i.id == _pendingFocusId)) {
          final id = _pendingFocusId!;
          _pendingFocusId = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNodeFor(id).requestFocus();
          });
        }

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
                      controller: widget.controllerFor(it),
                      focusNode: _focusNodeFor(it.id),
                      textInputAction: TextInputAction.next,
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
                      onSubmitted: (_) async {
                        final newId =
                            await repo.addItem(widget.noteId);
                        if (mounted) {
                          setState(() => _pendingFocusId = newId);
                        }
                      },
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove',
                    onPressed: () {
                      repo.deleteItem(it.id);
                      widget.onForgetController(it.id);
                      _focusNodes.remove(it.id)?.dispose();
                    },
                  ),
                ],
              ),
            TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
              onPressed: () => repo.addItem(widget.noteId),
            ),
          ],
        );
      },
    );
  }
}
