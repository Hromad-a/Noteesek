import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../export/share_note_sheet.dart';
import 'note_colors.dart';

enum _OverflowAction {
  convert,
  autoSort,
  share,
  moveToNotebook,
  archive,
  delete
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Formats a PocketBase-style ISO timestamp (e.g. "2026-06-05 00:14:58.581Z")
/// into a short local string like "6 Jun 2026, 14:30". Returns '' if unparseable.
String _fmtTimestamp(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${_months[dt.month - 1]} ${dt.year}, $h:$m';
}

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
  final _bodyFocus = FocusNode();
  bool _seeded = false;
  String? _seededType;

  // Per-item text controllers for checklists, keyed by item id.
  final Map<String, TextEditingController> _itemCtrls = {};

  NotesRepository get _repo => ref.read(notesRepositoryProvider);

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    for (final c in _itemCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _seed(NoteRow note) {
    if (!_seeded) {
      _titleCtrl.text = note.title;
      _bodyCtrl.text = note.body;
      _seeded = true;
      _seededType = note.type;
      return;
    }
    // After a type conversion, re-seed the body when the note became a text
    // note (its body was just rebuilt from the checklist items). Converting to
    // a checklist needs nothing here — the checklist editor reads items live.
    if (_seededType != note.type) {
      _seededType = note.type;
      if (note.type != 'checklist') _bodyCtrl.text = note.body;
    }
  }

  /// On leaving the editor, send the note to Trash if it's entirely empty:
  /// no title, no body / no non-blank checklist items, and no attachments.
  /// Lets a note created-and-abandoned vanish without clutter (restorable).
  void _discardIfEmpty(NoteRow note) {
    final titleEmpty = _titleCtrl.text.trim().isEmpty;
    final bool contentEmpty;
    if (note.type == 'checklist') {
      final items =
          ref.read(checklistItemsProvider(note.id)).asData?.value ?? const [];
      contentEmpty = items.every((i) => i.content.trim().isEmpty);
    } else {
      contentEmpty = _bodyCtrl.text.trim().isEmpty;
    }
    final atts =
        ref.read(attachmentsProvider(note.id)).asData?.value ?? const [];
    if (titleEmpty && contentEmpty && atts.isEmpty) {
      unawaited(_repo.softDelete(note.id));
    }
  }

  Future<void> _pickColor(NoteRow note) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Color', style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final c in kNoteColors)
                    _ColorSwatch(
                      noteColor: c,
                      selected: c.key == note.color,
                      onTap: () {
                        _repo.setColor(note.id, c.key);
                        Navigator.of(sheetContext).pop();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickLabels(String noteId) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _LabelPickerSheet(noteId: noteId),
    );
  }

  Future<void> _moveToNotebook(NoteRow note) async {
    final notebooks = ref.read(notebooksProvider).asData?.value ?? const [];
    if (notebooks.isEmpty) return;
    final known = {for (final n in notebooks) n.id};
    final defaultId = ref.read(defaultNotebookIdProvider);
    final current = effectiveNotebookId(note, known, defaultId);

    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Move to notebook',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final nb in notebooks)
                    ListTile(
                      leading: Icon(nb.id == current
                          ? Icons.book
                          : Icons.book_outlined),
                      title: Text(nb.name),
                      trailing:
                          nb.id == current ? const Icon(Icons.check) : null,
                      onTap: () => Navigator.of(sheetContext).pop(nb.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != note.notebook) {
      await _repo.setNoteNotebook(note.id, chosen);
    }
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
        final bg = noteColorFor(context, note.color);

        return PopScope(
          canPop: true,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) _discardIfEmpty(note);
          },
          child: Scaffold(
            backgroundColor: bg,
            appBar: AppBar(
              backgroundColor: bg,
              actions: [
                IconButton(
                  tooltip: 'Color',
                  icon: const Icon(Icons.palette_outlined),
                  onPressed: () => _pickColor(note),
                ),
                IconButton(
                  tooltip: 'Labels',
                  icon: const Icon(Icons.label_outline),
                  onPressed: () => _pickLabels(note.id),
                ),
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
                      case _OverflowAction.convert:
                        await _repo.convertNoteType(
                          note.id,
                          note.type == 'checklist' ? 'text' : 'checklist',
                        );
                      case _OverflowAction.autoSort:
                        await ref
                            .read(checklistAutoSortProvider.notifier)
                            .set(!ref.read(checklistAutoSortProvider));
                      case _OverflowAction.share:
                        await showShareNoteSheet(context, _repo, note.id);
                      case _OverflowAction.moveToNotebook:
                        await _moveToNotebook(note);
                      case _OverflowAction.archive:
                        await _repo.setArchived(note.id, !note.archived);
                      case _OverflowAction.delete:
                        await _repo.softDelete(note.id);
                        if (context.mounted) Navigator.of(context).maybePop();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _OverflowAction.convert,
                      child: ListTile(
                        leading: Icon(note.type == 'checklist'
                            ? Icons.notes_outlined
                            : Icons.checklist_outlined),
                        title: Text(note.type == 'checklist'
                            ? 'Convert to text'
                            : 'Convert to checklist'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    if (note.type == 'checklist')
                      PopupMenuItem(
                        value: _OverflowAction.autoSort,
                        child: ListTile(
                          leading: Icon(ref.watch(checklistAutoSortProvider)
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank),
                          title: const Text('Sort checked to bottom'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem(
                      value: _OverflowAction.share,
                      child: ListTile(
                        leading: Icon(Icons.ios_share),
                        title: Text('Share / export'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: _OverflowAction.moveToNotebook,
                      child: ListTile(
                        leading: Icon(Icons.drive_file_move_outlined),
                        title: Text('Move to notebook'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
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
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Title',
                      border: InputBorder.none,
                    ),
                    style: Theme.of(context).textTheme.titleLarge,
                    onChanged: (v) => _repo.updateNoteFields(note.id, title: v),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _AttachmentsSection(noteId: note.id),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _EditorLabels(note: note),
                ),
                Expanded(
                  child: note.type == 'checklist'
                      ? _ChecklistEditor(
                          noteId: note.id,
                          controllerFor: _itemCtrl,
                          onForgetController: (id) =>
                              _itemCtrls.remove(id)?.dispose(),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _bodyFocus.requestFocus(),
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: TextField(
                              controller: _bodyCtrl,
                              focusNode: _bodyFocus,
                              decoration: const InputDecoration(
                                hintText: 'Note',
                                border: InputBorder.none,
                              ),
                              expands: true,
                              maxLines: null,
                              minLines: null,
                              textAlignVertical: TextAlignVertical.top,
                              keyboardType: TextInputType.multiline,
                              onChanged: (v) =>
                                  _repo.updateNoteFields(note.id, body: v),
                            ),
                          ),
                        ),
                ),
              ],
            ),
            bottomNavigationBar: _TimestampBar(
              created: note.created,
              updated: note.updated,
              color: bg,
            ),
            floatingActionButton: FloatingActionButton(
              tooltip: 'Save & close',
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Icon(Icons.check),
            ),
          ),
        );
      },
    );
  }
}

/// Bottom bar showing when the note was created and last edited (bottom-left).
class _TimestampBar extends StatelessWidget {
  const _TimestampBar({
    required this.created,
    required this.updated,
    this.color,
  });

  final String? created;
  final String updated;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final createdStr = _fmtTimestamp(created);
    final updatedStr = _fmtTimestamp(updated);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

    return BottomAppBar(
      color: color,
      height: 56,
      // Leave room on the right for the floating check button.
      padding: const EdgeInsets.only(left: 16, right: 88),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (createdStr.isNotEmpty) Text('Created $createdStr', style: style),
            if (updatedStr.isNotEmpty) Text('Edited $updatedStr', style: style),
          ],
        ),
      ),
    );
  }
}

/// Chips for the labels currently assigned to the note, each removable. Hidden
/// when the note has no labels.
class _EditorLabels extends ConsumerWidget {
  const _EditorLabels({required this.note});

  final NoteRow note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assigned = labelIdsOf(note);
    if (assigned.isEmpty) return const SizedBox.shrink();
    final repo = ref.read(notesRepositoryProvider);
    final labels = ref.watch(labelsProvider).asData?.value ?? const [];
    final names = {for (final l in labels) l.id: l.name};

    final chips = [
      for (final id in assigned)
        if (names.containsKey(id))
          Chip(
            label: Text(names[id]!),
            visualDensity: VisualDensity.compact,
            onDeleted: () => repo.setNoteLabels(
              note.id,
              assigned.where((e) => e != id).toList(),
            ),
          ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 4, children: chips),
    );
  }
}

/// Bottom sheet to toggle the note's labels and create new ones inline.
class _LabelPickerSheet extends ConsumerStatefulWidget {
  const _LabelPickerSheet({required this.noteId});

  final String noteId;

  @override
  ConsumerState<_LabelPickerSheet> createState() => _LabelPickerSheetState();
}

class _LabelPickerSheetState extends ConsumerState<_LabelPickerSheet> {
  final _newCtrl = TextEditingController();

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _createAndAssign(List<String> current) async {
    final name = _newCtrl.text.trim();
    if (name.isEmpty) return;
    final repo = ref.read(notesRepositoryProvider);
    final id = await repo.createLabel(name);
    await repo.setNoteLabels(widget.noteId, [...current, id]);
    _newCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(notesRepositoryProvider);
    final note = ref.watch(noteProvider(widget.noteId)).asData?.value;
    final labels = ref.watch(labelsProvider).asData?.value ?? const [];
    final assigned = note == null ? <String>[] : labelIdsOf(note);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Labels', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in labels)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: assigned.contains(l.id),
                      title: Text(l.name),
                      onChanged: (checked) {
                        final next = [...assigned];
                        if (checked ?? false) {
                          next.add(l.id);
                        } else {
                          next.remove(l.id);
                        }
                        repo.setNoteLabels(widget.noteId, next);
                      },
                    ),
                ],
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Create new label',
                      prefixIcon: Icon(Icons.add),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _createAndAssign(assigned),
                  ),
                ),
                TextButton(
                  onPressed: () => _createAndAssign(assigned),
                  child: const Text('Add'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A circular color swatch in the editor's palette sheet. The default color
/// (empty key) is drawn as a "no color" outline with a reset icon.
class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.noteColor,
    required this.selected,
    required this.onTap,
  });

  final NoteColor noteColor;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDefault = noteColor.key.isEmpty;
    final fill = noteSwatchFor(context, noteColor.key);
    final outline = Theme.of(context).colorScheme.outline;
    final primary = Theme.of(context).colorScheme.primary;

    return Tooltip(
      message: noteColor.label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? primary : outline,
              width: selected ? 3 : 1,
            ),
          ),
          child: isDefault
              ? Icon(Icons.format_color_reset_outlined, size: 20, color: outline)
              : selected
                  ? Icon(Icons.check, size: 20, color: primary)
                  : null,
        ),
      ),
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
          padding: const EdgeInsets.only(top: 8, bottom: 4),
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

  /// Whether the collapsible "completed" section (auto-sort mode) is expanded.
  bool _completedExpanded = false;

  FocusNode _focusNodeFor(String id) =>
      _focusNodes.putIfAbsent(id, () => FocusNode());

  Future<void> _addAndFocus({String content = ''}) async {
    final newId = await ref
        .read(notesRepositoryProvider)
        .addItem(widget.noteId, content: content);
    if (mounted) {
      setState(() => _pendingFocusId = newId);
    }
  }

  /// Handles edits to an item. The field is multi-line (so long text wraps), so
  /// a newline means the user pressed Enter: keep the text before the break on
  /// this item and push the remainder into a new item below (preserving the
  /// single-line "Enter adds the next item" feel).
  void _onItemChanged(ChecklistItemRow item, String value) {
    final repo = ref.read(notesRepositoryProvider);
    final br = value.indexOf('\n');
    if (br < 0) {
      repo.setItemContent(item.id, value);
      return;
    }
    final head = value.substring(0, br);
    final tail = value.substring(br + 1).replaceAll('\n', '');
    widget.controllerFor(item).value = TextEditingValue(
      text: head,
      selection: TextSelection.collapsed(offset: head.length),
    );
    repo.setItemContent(item.id, head);
    _addAndFocus(content: tail);
  }

  @override
  void dispose() {
    for (final fn in _focusNodes.values) {
      fn.dispose();
    }
    super.dispose();
  }

  /// One checklist row. When [dragIndex] is non-null the row carries a drag
  /// handle that starts a reorder at that index; completed rows pass null.
  Widget _itemRow(ChecklistItemRow it, {int? dragIndex}) {
    final repo = ref.read(notesRepositoryProvider);
    return Row(
      // Top-align so the controls stay on the first line when an item wraps.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dragIndex != null)
          ReorderableDragStartListener(
            index: dragIndex,
            child: const Padding(
              padding: EdgeInsets.only(top: 12, right: 4),
              child: Icon(Icons.drag_indicator, size: 18, color: Colors.grey),
            ),
          )
        else
          const SizedBox(width: 26),
        Checkbox(
          value: it.checked,
          onChanged: (v) => repo.setItemChecked(it.id, v ?? false),
        ),
        Expanded(
          child: TextField(
            controller: widget.controllerFor(it),
            focusNode: _focusNodeFor(it.id),
            // Multi-line so long items wrap and stay fully visible; Enter is
            // intercepted in _onItemChanged to add the next item instead of a
            // line break.
            minLines: 1,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'List item',
            ),
            style: it.checked
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
            onChanged: (v) => _onItemChanged(it, v),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(notesRepositoryProvider);
    final autoSort = ref.watch(checklistAutoSortProvider);
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

        // In auto-sort mode, checked items sink to a separate "completed"
        // section; otherwise all items stay in their manual order and are
        // reorderable in place.
        final active =
            autoSort ? items.where((i) => !i.checked).toList() : items;
        final completed = autoSort
            ? items.where((i) => i.checked).toList()
            : const <ChecklistItemRow>[];

        void onReorder(int oldIndex, int newIndex) {
          if (newIndex > oldIndex) newIndex -= 1;
          final reordered = [...active];
          reordered.insert(newIndex, reordered.removeAt(oldIndex));
          // Persist the active order followed by the (unchanged) completed
          // items so positions stay contiguous across the whole list.
          repo.reorderItems(
            [...reordered, ...completed].map((e) => e.id).toList(),
          );
        }

        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverReorderableList(
                itemCount: active.length,
                // onReorderItem (its replacement) postdates our SDK floor
                // (^3.12.0, per pubspec), so stick with onReorder for now.
                // ignore: deprecated_member_use
                onReorder: onReorder,
                itemBuilder: (context, i) => KeyedSubtree(
                  key: ValueKey(active[i].id),
                  child: _itemRow(active[i], dragIndex: i),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add item'),
                        onPressed: _addAndFocus,
                      ),
                    ),
                    if (completed.isNotEmpty) ...[
                      const Divider(),
                      InkWell(
                        onTap: () => setState(
                            () => _completedExpanded = !_completedExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              Icon(
                                _completedExpanded
                                    ? Icons.expand_more
                                    : Icons.chevron_right,
                                size: 20,
                              ),
                              const SizedBox(width: 4),
                              Text('${completed.length} completed',
                                  style: Theme.of(context).textTheme.labelLarge),
                            ],
                          ),
                        ),
                      ),
                      if (_completedExpanded)
                        for (final it in completed) _itemRow(it),
                    ],
                  ],
                ),
              ),
            ),
            // Tappable filler: tapping in the empty area below adds an item.
            SliverFillRemaining(
              hasScrollBody: false,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _addAndFocus,
                child: const SizedBox(width: double.infinity, height: 80),
              ),
            ),
          ],
        );
      },
    );
  }
}
