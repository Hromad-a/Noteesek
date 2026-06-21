import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../data/local/database.dart';
import '../../data/local/ids.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../../ui/app_messenger.dart';
import '../export/share_note_sheet.dart';
import 'note_colors.dart';
import 'note_markdown_config.dart';
import 'notebook_share_sheet.dart';
import 'sharing_service.dart';

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

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen>
    with WidgetsBindingObserver {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _bodyFocus = FocusNode();
  final _undoController = UndoHistoryController();
  bool _seeded = false;
  String? _seededType;

  /// When Markdown is enabled, toggles the text body between editing and a
  /// rendered read view.
  bool _previewMarkdown = false;

  // Per-item text controllers for checklists, keyed by item id.
  final Map<String, TextEditingController> _itemCtrls = {};

  // Shared-notebook edit lock (Phase 4). While editing a note in a shared
  // notebook this screen holds the lock and heartbeats it; others see the note
  // read-only. See docs/shared-notebooks.md.
  Timer? _heartbeat;
  bool _holdingLock = false;

  NotesRepository get _repo => ref.read(notesRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    if (_holdingLock) {
      // Release so the note frees up immediately for others (pushed at once on
      // mobile so the other device doesn't wait for the next periodic sync).
      _setLock(widget.noteId, '', '');
    }
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _bodyFocus.dispose();
    _undoController.dispose();
    for (final c in _itemCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Coming back from background (e.g. the phone was locked with the note open):
  /// our heartbeat was suspended, so the lock may have gone stale or been taken.
  /// Forget our hold *without* releasing on the server, pull fresh state, then
  /// let build() + [_manageLock] re-acquire it if it's free, or drop us to
  /// read-only if another member now holds it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Forget any (possibly stale) hold without releasing on the server, then
    // re-evaluate from fresh data.
    _holdingLock = false;
    _heartbeat?.cancel();
    if (!kIsWeb) {
      ref.read(syncControllerProvider.notifier).syncNow().then((_) {
        if (mounted) setState(() {});
      });
    } else if (mounted) {
      setState(() {});
    }
  }

  /// Whether the note's notebook is shared with anyone.
  bool _isShared(NoteRow note) {
    if (note.notebook.isEmpty) return false;
    final notebooks = ref.read(notebooksProvider).asData?.value ?? const [];
    final nb =
        notebooks.cast<NotebookRow?>().firstWhere((n) => n?.id == note.notebook,
            orElse: () => null);
    return nb != null && sharedWithIds(nb.sharedWith).isNotEmpty;
  }

  /// Writes the lock and, on mobile, pushes it to the server immediately so the
  /// other device sees it without waiting for the next periodic sync. (On web
  /// [NotesRepository.setNoteLock] already hits the server directly.)
  void _setLock(String id, String by, String at) {
    _repo.setNoteLock(id, by, at);
    if (!kIsWeb) ref.read(syncControllerProvider.notifier).syncNow();
  }

  /// Drives the edit lock as a side effect of [build]: acquire + heartbeat when
  /// we may edit a shared note, release when we can't (read-only / left). Only
  /// fires writes on a state transition, so it's safe to call every build.
  /// [currentLockedBy] guards the release: we never clear a lock that's now held
  /// by someone else (a takeover after our lock went stale).
  void _manageLock(String id, bool canEdit, String currentLockedBy) {
    final me = _myId();
    if (canEdit && !_holdingLock) {
      _holdingLock = true;
      _setLock(id, me, pbNow());
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(kLockHeartbeat, (_) {
        if (_holdingLock) _setLock(id, me, pbNow());
      });
    } else if (!canEdit && _holdingLock) {
      _holdingLock = false;
      _heartbeat?.cancel();
      if (currentLockedBy.isEmpty || currentLockedBy == me) {
        _setLock(id, '', '');
      }
    }
  }

  String _myId() => ref.read(authUserIdProvider);

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
    final known = {for (final n in notebooks) n.id};
    // The note's current notebook, or '' (no notebook) when empty/unknown.
    final current =
        note.notebook.isNotEmpty && known.contains(note.notebook)
            ? note.notebook
            : '';

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
                  ListTile(
                    leading: Icon(current.isEmpty
                        ? Icons.check
                        : Icons.label_off_outlined),
                    title: const Text('No notebook'),
                    onTap: () => Navigator.of(sheetContext).pop(''),
                  ),
                  for (final nb in notebooks)
                    ListTile(
                      leading: Icon(nb.id == current
                          ? Icons.check
                          : Icons.book_outlined),
                      title: Text(nb.name),
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
        final markdownOn = ref.watch(markdownEnabledProvider);

        // Shared-notebook concurrency: a note in a shared notebook is read-only
        // when the server is unreachable (online-only editing) or another member
        // currently holds a fresh lock. Otherwise we take the lock + heartbeat.
        final shared = _isShared(note);
        final me = ref.watch(authUserIdProvider);
        final reachable =
            kIsWeb ? true : ref.watch(syncControllerProvider).reachable;
        final lockedByOther = shared &&
            note.lockedBy.isNotEmpty &&
            note.lockedBy != me &&
            lockIsFresh(note.lockedAt);
        final readOnly = shared && (!reachable || lockedByOther);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _manageLock(note.id, shared && !readOnly, note.lockedBy);
        });
        // While read-only (someone else is editing), keep the displayed text in
        // sync with incoming live updates — _seed only runs once, so refresh the
        // controllers here. Safe because the user can't be typing in read-only.
        if (readOnly) {
          if (_titleCtrl.text != note.title) _titleCtrl.text = note.title;
          if (note.type != 'checklist' && _bodyCtrl.text != note.body) {
            _bodyCtrl.text = note.body;
          }
        }

        // The editing toolbar floats above the keyboard on mobile, so it only
        // shows while the keyboard is up. Web has no soft keyboard, so keep it
        // present the whole time a text note is open.
        final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
        final showEditingBar = note.type == 'text' &&
            !_previewMarkdown &&
            !readOnly &&
            (kIsWeb || keyboardOpen);

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
                if (shared)
                  IconButton(
                    tooltip: 'Shared notebook — members',
                    icon: const Icon(Icons.group_outlined),
                    onPressed: () =>
                        showNotebookShareSheet(context, note.notebook),
                  ),
                if (readOnly)
                  // Read-only: no edit affordances (the lock/offline banner in
                  // the body explains why).
                  const SizedBox.shrink()
                else ...[
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
                if (markdownOn && note.type == 'text')
                  IconButton(
                    tooltip: _previewMarkdown ? 'Edit' : 'Preview',
                    icon: Icon(_previewMarkdown
                        ? Icons.edit_outlined
                        : Icons.visibility_outlined),
                    onPressed: () =>
                        setState(() => _previewMarkdown = !_previewMarkdown),
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
                        final repo = _repo;
                        await repo.softDelete(note.id);
                        showUndoSnackBar(
                          message: 'Note moved to Trash',
                          onUndo: () => repo.restore(note.id),
                        );
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
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (readOnly) _LockBanner(note: note, offline: !reachable),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: TextField(
                    controller: _titleCtrl,
                    readOnly: readOnly,
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
                  child: _AttachmentsSection(noteId: note.id, readOnly: readOnly),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _EditorLabels(note: note, readOnly: readOnly),
                ),
                Expanded(
                  child: note.type == 'checklist'
                      ? _ChecklistEditor(
                          noteId: note.id,
                          controllerFor: _itemCtrl,
                          readOnly: readOnly,
                          onForgetController: (id) =>
                              _itemCtrls.remove(id)?.dispose(),
                        )
                      : (markdownOn && _previewMarkdown)
                          ? _MarkdownPreview(text: note.body)
                          : Column(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => _bodyFocus.requestFocus(),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16, 8, 16, 16),
                                      child: TextField(
                                        controller: _bodyCtrl,
                                        focusNode: _bodyFocus,
                                        readOnly: readOnly,
                                        undoController: _undoController,
                                        decoration: const InputDecoration(
                                          hintText: 'Note',
                                          border: InputBorder.none,
                                        ),
                                        expands: true,
                                        maxLines: null,
                                        minLines: null,
                                        textAlignVertical:
                                            TextAlignVertical.top,
                                        keyboardType: TextInputType.multiline,
                                        onChanged: (v) => _repo
                                            .updateNoteFields(note.id, body: v),
                                      ),
                                    ),
                                  ),
                                ),
                                // The formatting + undo/redo pill lives at the
                                // bottom of the *body* so it floats directly
                                // above the keyboard. (In a bottomNavigationBar
                                // it would be hidden *behind* the keyboard —
                                // exactly when it's meant to show.)
                                if (showEditingBar)
                                  _MarkdownToolbar(
                                    controller: _bodyCtrl,
                                    undoController: _undoController,
                                    showFormatting: markdownOn,
                                    onChanged: (v) => _repo
                                        .updateNoteFields(note.id, body: v),
                                  ),
                              ],
                            ),
                ),
              ],
            ),
            // While editing, the toolbar (in the body) replaces this; when not
            // editing, show the timestamps.
            bottomNavigationBar: showEditingBar
                ? null
                : _TimestampBar(
                    created: note.created,
                    updated: note.updated,
                    color: bg,
                  ),
            // Hide the check button while the toolbar is up so it doesn't
            // cover the bar (back still saves; it returns when typing stops).
            floatingActionButton: showEditingBar
                ? null
                : FloatingActionButton(
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

/// Read-only banner shown atop a shared note that can't be edited right now:
/// either the server is unreachable (online-only editing) or another member
/// holds the edit lock.
class _LockBanner extends ConsumerWidget {
  const _LockBanner({required this.note, required this.offline});
  final NoteRow note;
  final bool offline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final IconData icon;
    final String msg;
    if (offline) {
      icon = Icons.cloud_off_outlined;
      msg = 'Offline — connect to your server to edit this shared note.';
    } else {
      icon = Icons.lock_outline;
      final users =
          ref.watch(shareableUsersProvider).asData?.value ?? const [];
      final email = users
          .cast<ShareableUser?>()
          .firstWhere((u) => u?.id == note.lockedBy, orElse: () => null)
          ?.email;
      msg = email != null
          ? 'Being edited by $email'
          : 'Another member is editing this note.';
    }
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(msg,
                  style: TextStyle(color: scheme.onSecondaryContainer)),
            ),
          ],
        ),
      ),
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
  const _EditorLabels({required this.note, this.readOnly = false});

  final NoteRow note;
  final bool readOnly;

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
            onDeleted: readOnly
                ? null
                : () => repo.setNoteLabels(
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
  const _AttachmentsSection({required this.noteId, this.readOnly = false});

  final String noteId;
  final bool readOnly;

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
                    if (!readOnly)
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
    this.readOnly = false,
  });

  final String noteId;
  final TextEditingController Function(ChecklistItemRow) controllerFor;
  final void Function(String id) onForgetController;
  final bool readOnly;

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

  /// Height of one checklist line: the controls are centred within this so a
  /// single-line item reads as vertically centred next to the checkbox, while a
  /// wrapped (multi-line) item keeps the controls pinned to the first line.
  static const double _lineHeight = 40;

  /// One checklist row. When [dragIndex] is non-null the row carries a drag
  /// handle that starts a reorder at that index; completed rows pass null.
  Widget _itemRow(ChecklistItemRow it, {int? dragIndex}) {
    final repo = ref.read(notesRepositoryProvider);
    return Row(
      // Top-align the whole row so a wrapped item grows downward; each control
      // is itself centred within one line-height so it lines up with the text.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          height: _lineHeight,
          child: dragIndex != null && !widget.readOnly
              ? Center(
                  child: ReorderableDragStartListener(
                    index: dragIndex,
                    child: const Icon(Icons.drag_indicator,
                        size: 18, color: Colors.grey),
                  ),
                )
              : null,
        ),
        SizedBox(
          height: _lineHeight,
          child: Center(
            child: Checkbox(
              value: it.checked,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: widget.readOnly
                  ? null
                  : (v) => repo.setItemChecked(it.id, v ?? false),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: widget.controllerFor(it),
            focusNode: _focusNodeFor(it.id),
            readOnly: widget.readOnly,
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
              // Vertically pad a single line up to _lineHeight so its text
              // centres against the checkbox.
              contentPadding: EdgeInsets.symmetric(vertical: 9),
            ),
            style: it.checked
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
            onChanged: (v) => _onItemChanged(it, v),
          ),
        ),
        if (!widget.readOnly)
          SizedBox(
            height: _lineHeight,
            child: Center(
              child: IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove',
                onPressed: () {
                  repo.deleteItem(it.id);
                  widget.onForgetController(it.id);
                  _focusNodes.remove(it.id)?.dispose();
                },
              ),
            ),
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
                    if (!widget.readOnly)
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
                onTap: widget.readOnly ? null : _addAndFocus,
                child: const SizedBox(width: double.infinity, height: 80),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Read-only Markdown render of a note body (the editor's preview mode).
class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Text('Nothing to preview',
            style: TextStyle(color: Theme.of(context).disabledColor)),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: MarkdownBlock(
        data: text,
        config: noteMarkdownConfig(context),
      ),
    );
  }
}

/// A compact Markdown formatting toolbar that edits [controller] in place
/// (wrapping the selection or prefixing the current line) and reports the new
/// text via [onChanged] so the editor persists it.
class _MarkdownToolbar extends StatelessWidget {
  const _MarkdownToolbar({
    required this.controller,
    required this.undoController,
    required this.onChanged,
    required this.showFormatting,
  });

  final TextEditingController controller;
  final UndoHistoryController undoController;
  final ValueChanged<String> onChanged;

  /// When false (Markdown off) only undo/redo show — no formatting buttons.
  final bool showFormatting;

  /// Selection clamped to a valid range (cursor at end when unfocused).
  (int, int) get _range {
    final s = controller.selection;
    if (s.start < 0) return (controller.text.length, controller.text.length);
    return (s.start, s.end);
  }

  void _wrap(String left, String right) {
    final (start, end) = _range;
    final text = controller.text;
    final selected = text.substring(start, end);
    final replaced = '$left$selected$right';
    final newText = text.replaceRange(start, end, replaced);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: end + left.length),
    );
    onChanged(newText);
  }

  void _linePrefix(String prefix) {
    final (start, _) = _range;
    final text = controller.text;
    final lineStart =
        start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    final newText = text.replaceRange(lineStart, lineStart, prefix);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + prefix.length),
    );
    onChanged(newText);
  }

  @override
  Widget build(BuildContext context) {
    // [onTap] may be null to render the button disabled (greyed out).
    Widget btn(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
        );

    // Undo/redo reflect the live history; they pin to the left of the bar.
    final history = ValueListenableBuilder<UndoHistoryValue>(
      valueListenable: undoController,
      builder: (context, value, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn(Icons.undo, 'Undo',
              value.canUndo ? undoController.undo : null),
          btn(Icons.redo, 'Redo',
              value.canRedo ? undoController.redo : null),
        ],
      ),
    );

    final formatting = showFormatting
        ? Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  btn(Icons.format_bold, 'Bold', () => _wrap('**', '**')),
                  btn(Icons.format_italic, 'Italic', () => _wrap('*', '*')),
                  btn(Icons.title, 'Heading', () => _linePrefix('# ')),
                  btn(Icons.format_list_bulleted, 'Bullet list',
                      () => _linePrefix('- ')),
                  btn(Icons.checklist, 'Checkbox',
                      () => _linePrefix('- [ ] ')),
                  btn(Icons.format_quote, 'Quote', () => _linePrefix('> ')),
                  btn(Icons.code, 'Code', () => _wrap('`', '`')),
                  btn(Icons.link, 'Link', () => _wrap('[', '](url)')),
                ],
              ),
            ),
          )
        : const Spacer();

    // [ExcludeFocus] keeps taps from stealing focus off the body field, so the
    // keyboard stays up and undo/redo/formatting apply to the live editor.
    return ExcludeFocus(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            elevation: 3,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  history,
                  if (showFormatting)
                    const SizedBox(
                      height: 24,
                      child: VerticalDivider(width: 8, thickness: 1),
                    ),
                  formatting,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
