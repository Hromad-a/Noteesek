import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../../ui/app_messenger.dart';
import '../auth/login_screen.dart';
import '../capture/quick_capture.dart';
import '../auth/settings_screen.dart';
import '../export/share_note_sheet.dart';
import 'archive_screen.dart';
import 'label_notes_screen.dart';
import 'manage_labels_screen.dart';
import 'manage_notebooks_screen.dart';
import 'note_card.dart';
import 'note_colors.dart';
import 'note_editor_screen.dart';
import 'note_selection.dart';
import 'trash_screen.dart';

/// Home screen: a Keep-style masonry grid of notes with a create FAB.
class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});

  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    // Make sure the user has a default notebook (and reconcile duplicates),
    // then repair any notebooks stranded by a previous merge.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repo = ref.read(notesRepositoryProvider);
      await repo.healNotebooks();
      await repo.ensureDefaultNotebook();
    });
    if (!kIsWeb) _initShareCapture();
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  /// Quick capture: a share from another app (text/images) → a new note.
  /// Handles both a cold launch via share and shares while already running.
  void _initShareCapture() {
    ReceiveSharingIntent.instance.getInitialMedia().then((media) {
      if (media.isNotEmpty) {
        _onShared(media);
        ReceiveSharingIntent.instance.reset();
      }
    });
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(_onShared);
  }

  Future<void> _onShared(List<SharedMediaFile> media) async {
    final id = await QuickCapture.createNote(
        ref.read(notesRepositoryProvider), media);
    if (id != null && mounted) _open(context, id);
  }

  Future<void> _create(BuildContext context, WidgetRef ref, String type) async {
    final notebook = ref.read(activeNotebookIdProvider);
    final id = await ref
        .read(notesRepositoryProvider)
        .createNote(type: type, notebook: notebook);
    // createNote returns '' if the write failed (web, server unreachable); the
    // repository already surfaced a message, so just don't open a phantom note.
    if (id.isEmpty) return;
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

  Future<void> _manualSync(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome =
        await ref.read(syncControllerProvider.notifier).syncNow(manual: true);
    if (!context.mounted) return;
    final text = switch (outcome) {
      SyncOutcome.ok => 'Synced',
      SyncOutcome.busy => 'Sync already in progress',
      SyncOutcome.notConnected => 'Connect a server to sync',
      SyncOutcome.unreachable =>
        'Server not responding — your notes are saved on this device',
      SyncOutcome.failed =>
        ref.read(syncControllerProvider).message ?? 'Sync failed',
    };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _onReorder(WidgetRef ref, String draggedId, String targetId, List<NoteRow> notes) {
    if (draggedId == targetId) return;
    final dragged = notes.firstWhere((n) => n.id == draggedId,
        orElse: () => notes.first);
    final target =
        notes.firstWhere((n) => n.id == targetId, orElse: () => notes.first);
    if (dragged.id != draggedId || target.id != targetId) return;
    if (dragged.pinned != target.pinned) return;

    final section = notes.where((n) => n.pinned == dragged.pinned).toList();
    final fromIdx = section.indexWhere((n) => n.id == draggedId);
    final toIdx = section.indexWhere((n) => n.id == targetId);
    if (fromIdx < 0 || toIdx < 0 || fromIdx == toIdx) return;

    section.removeAt(fromIdx);
    section.insert(toIdx, dragged);
    ref
        .read(notesRepositoryProvider)
        .reorderNotes(section.map((n) => n.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    final notesAsync = ref.watch(activeNotesProvider);
    final pb = ref.watch(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';
    final connected = ref.watch(isAuthenticatedProvider);
    final sync = kIsWeb ? null : ref.watch(syncControllerProvider);
    final hasPending =
        kIsWeb ? false : ref.watch(hasPendingChangesProvider).value ?? false;
    final selectionMode = ref.watch(selectionModeProvider);
    final viewMode = ref.watch(noteViewModeProvider);
    final sort = ref.watch(noteSortProvider);
    // Drag-to-reorder only defines the custom order, so it's disabled under a
    // date sort (long-press still selects — see NoteCard).
    final reorderable = sort.field == NoteSortField.custom;

    return PopScope(
      canPop: !selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) ref.read(noteSelectionProvider.notifier).clear();
      },
      child: Scaffold(
        drawer: _AppDrawer(email: email, connected: connected),
        appBar: selectionMode
            ? const _SelectionAppBar()
            : AppBar(
                title: const Text('Notes'),
                actions: [
          IconButton(
            tooltip: viewMode == NoteViewMode.grid
                ? 'Single-column view'
                : 'Grid view',
            icon: Icon(viewMode == NoteViewMode.grid
                ? Icons.view_agenda_outlined
                : Icons.grid_view_outlined),
            onPressed: () => ref.read(noteViewModeProvider.notifier).toggle(),
          ),
          _SortMenu(sort: sort),
          if (sync != null) ...[
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
            else if (!connected)
              IconButton(
                tooltip: 'Connect a server to sync',
                icon: const Icon(Icons.cloud_off_outlined),
                onPressed: null,
              )
            else if (!sync.reachable)
              IconButton(
                tooltip: 'Offline — tap to retry',
                icon: Icon(Icons.cloud_off,
                    color: Theme.of(context).colorScheme.error),
                onPressed: () => _manualSync(context, ref),
              )
            else if (hasPending)
              IconButton(
                tooltip: 'Changes not synced yet — tap to sync now',
                icon: const Icon(Icons.cloud_upload_outlined),
                onPressed: () => _manualSync(context, ref),
              )
            else
              IconButton(
                tooltip: 'Synced — tap to sync now',
                icon: const Icon(Icons.cloud_done_outlined),
                onPressed: () => _manualSync(context, ref),
              ),
          ],
                ],
              ),
        body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _SearchField(),
            ),
            Expanded(
              // Pull-to-refresh forces a sync (mobile only — web is realtime).
              child: _SyncRefresh(
                onRefresh:
                    kIsWeb ? null : () => _manualSync(context, ref),
                child: notesAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (notes) {
                  if (notes.isEmpty) {
                    final searching =
                        ref.watch(searchQueryProvider).trim().isNotEmpty ||
                            ref.watch(searchFiltersProvider).isActive;
                    // Scrollable so pull-to-refresh works with no notes (e.g. a
                    // freshly-connected device syncing down for the first time).
                    return _ScrollableFill(
                      child: searching
                          ? const _NoMatches()
                          : const _EmptyState(),
                    );
                  }
                  Widget itemBuilder(BuildContext context, int i) {
                    final note = notes[i];
                    // Under a date sort, cards aren't draggable — render the
                    // card directly (long-press still selects).
                    if (!reorderable) {
                      return NoteCard(
                        note: note,
                        onTap: () => _open(context, note.id),
                        selectable: true,
                      );
                    }
                    return DragTarget<String>(
                      onWillAcceptWithDetails: (details) =>
                          details.data != note.id,
                      onAcceptWithDetails: (details) =>
                          _onReorder(ref, details.data, note.id, notes),
                      builder: (context, candidates, _) {
                        return NoteCard(
                          note: note,
                          onTap: () => _open(context, note.id),
                          isDragTarget: candidates.isNotEmpty,
                          selectable: true,
                          reorderable: true,
                        );
                      },
                    );
                  }

                  return Padding(
                    padding: const EdgeInsets.all(8),
                    child: viewMode == NoteViewMode.column
                        ? MasonryGridView.count(
                            // Always scrollable so pull-to-refresh fires even
                            // when the notes don't fill the viewport.
                            physics: const AlwaysScrollableScrollPhysics(),
                            crossAxisCount: 1,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            itemCount: notes.length,
                            itemBuilder: itemBuilder,
                          )
                        : MasonryGridView.extent(
                            physics: const AlwaysScrollableScrollPhysics(),
                            maxCrossAxisExtent: 240,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            itemCount: notes.length,
                            itemBuilder: itemBuilder,
                          ),
                  );
                },
                ),
              ),
            ),
          ],
        ),
      ),
        bottomNavigationBar: _BottomBar(
          onText: () => _create(context, ref, 'text'),
          onChecklist: () => _create(context, ref, 'checklist'),
        ),
      ),
    );
  }
}

/// Contextual app bar shown while one or more notes are selected. Its actions
/// mirror the note editor's top bar but operate on the whole selection at once.
class _SelectionAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _SelectionAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  Future<void> _pickColor(
      BuildContext context, NotesRepository repo, Set<String> ids) async {
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
              Text('Color',
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final c in kNoteColors)
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () async {
                        await Future.wait(
                            ids.map((id) => repo.setColor(id, c.key)));
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor:
                            noteColorFor(sheetContext, c.key) ??
                                Theme.of(sheetContext)
                                    .colorScheme
                                    .surfaceContainerHighest,
                        child: c.key.isEmpty
                            ? const Icon(Icons.format_color_reset_outlined,
                                size: 20)
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickLabels(
      BuildContext context, NotesRepository repo, Set<String> ids) async {
    final chosen = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _BulkLabelSheet(),
    );
    if (chosen == null) return;
    await Future.wait(ids.map((id) => repo.setNoteLabels(id, chosen)));
  }

  Future<void> _moveToNotebook(
      BuildContext context, WidgetRef ref, Set<String> ids) async {
    final notebooks = ref.read(notebooksProvider).asData?.value ?? const [];
    if (notebooks.isEmpty) return;
    final repo = ref.read(notesRepositoryProvider);
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
                      leading: const Icon(Icons.book_outlined),
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
    if (chosen == null) return;
    await Future.wait(ids.map((id) => repo.setNoteNotebook(id, chosen)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(noteSelectionProvider);
    final selection = ref.read(noteSelectionProvider.notifier);
    final repo = ref.read(notesRepositoryProvider);

    // Look at the current notes to decide the pin/archive toggle direction.
    final notes = ref.watch(activeNotesProvider).asData?.value ?? const [];
    final selected = notes.where((n) => ids.contains(n.id)).toList();
    final allPinned =
        selected.isNotEmpty && selected.every((n) => n.pinned);

    void done() => selection.clear();

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Cancel',
        onPressed: done,
      ),
      title: Text('${ids.length} selected'),
      actions: [
        IconButton(
          tooltip: allPinned ? 'Unpin' : 'Pin',
          icon: Icon(allPinned ? Icons.push_pin : Icons.push_pin_outlined),
          onPressed: () async {
            await Future.wait(
                ids.map((id) => repo.setPinned(id, !allPinned)));
            done();
          },
        ),
        IconButton(
          tooltip: 'Color',
          icon: const Icon(Icons.palette_outlined),
          onPressed: () async {
            await _pickColor(context, repo, ids);
            done();
          },
        ),
        IconButton(
          tooltip: 'Labels',
          icon: const Icon(Icons.label_outline),
          onPressed: () async {
            await _pickLabels(context, repo, ids);
            done();
          },
        ),
        PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'share':
                // Single-note export only — offered when exactly one is picked.
                await showShareNoteSheet(context, repo, ids.first);
                done();
              case 'archive':
                await Future.wait(
                    ids.map((id) => repo.setArchived(id, true)));
                done();
              case 'move':
                await _moveToNotebook(context, ref, ids);
                done();
              case 'delete':
                final deleted = ids.toList();
                await Future.wait(deleted.map((id) => repo.softDelete(id)));
                showUndoSnackBar(
                  message: deleted.length == 1
                      ? 'Note moved to Trash'
                      : '${deleted.length} notes moved to Trash',
                  onUndo: () {
                    for (final id in deleted) {
                      repo.restore(id);
                    }
                  },
                );
                done();
            }
          },
          itemBuilder: (context) => [
            if (ids.length == 1)
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.ios_share),
                  title: Text('Share / export'),
                ),
              ),
            const PopupMenuItem(
              value: 'archive',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.archive_outlined),
                title: Text('Archive'),
              ),
            ),
            const PopupMenuItem(
              value: 'move',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.drive_file_move_outlined),
                title: Text('Move to notebook'),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline),
                title: Text('Delete'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Bottom sheet that picks a set of labels to apply (overwriting) to the
/// whole selection. Pops the chosen label-id list, or null if cancelled.
class _BulkLabelSheet extends ConsumerStatefulWidget {
  @override
  ConsumerState<_BulkLabelSheet> createState() => _BulkLabelSheetState();
}

class _BulkLabelSheetState extends ConsumerState<_BulkLabelSheet> {
  final Set<String> _chosen = {};

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelsProvider).asData?.value ?? const [];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Apply labels',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (labels.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No labels yet'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final l in labels)
                      CheckboxListTile(
                        value: _chosen.contains(l.id),
                        title: Text(l.name),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _chosen.add(l.id);
                          } else {
                            _chosen.remove(l.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pop(_chosen.toList()),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App-bar sort control: pick the order field and flip the direction. Custom is
/// the manual drag-reorder order; the date fields default to newest-first.
class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.sort});

  final NoteSort sort;

  static const _ascValue = '__asc__';

  String _label(NoteSortField f) => switch (f) {
        NoteSortField.custom => 'Custom order',
        NoteSortField.edited => 'Date edited',
        NoteSortField.created => 'Date created',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(noteSortProvider.notifier);
    return PopupMenuButton<String>(
      tooltip: 'Sort notes',
      icon: const Icon(Icons.sort),
      onSelected: (value) {
        if (value == _ascValue) {
          notifier.setAscending(!sort.ascending);
        } else {
          notifier.setField(NoteSortField.values.byName(value));
        }
      },
      itemBuilder: (context) => [
        for (final f in NoteSortField.values)
          CheckedPopupMenuItem(
            value: f.name,
            checked: sort.field == f,
            child: Text(_label(f)),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _ascValue,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(sort.ascending
                ? Icons.arrow_upward
                : Icons.arrow_downward),
            title: Text(sort.ascending ? 'Ascending' : 'Descending'),
          ),
        ),
      ],
    );
  }
}

/// Bottom bar: the notebook selector on the left (switch / create / manage),
/// the new-checklist and new-note buttons on the right.
class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.onText, required this.onChecklist});

  final VoidCallback onText;
  final VoidCallback onChecklist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BottomAppBar(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Expanded(child: _NotebookSelector()),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'New checklist',
            onPressed: onChecklist,
            icon: const Icon(Icons.checklist),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'New note',
            onPressed: onText,
            icon: const Icon(Icons.edit),
          ),
        ],
      ),
    );
  }
}

/// A pill showing the current notebook; tapping opens a menu to switch
/// notebooks, create a new one, or manage them.
class _NotebookSelector extends ConsumerWidget {
  const _NotebookSelector();

  // Sentinel values for the non-notebook menu entries.
  static const _newValue = '__new_notebook__';
  static const _manageValue = '__manage_notebooks__';

  Future<void> _createNotebook(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New notebook'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Notebook name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    final id = await ref.read(notesRepositoryProvider).createNotebook(name);
    await ref.read(selectedNotebookIdProvider.notifier).set(id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
    final activeId = ref.watch(activeNotebookIdProvider);
    final active = notebooks.where((n) => n.id == activeId).firstOrNull;
    final name = active?.name ?? 'Notebook';

    return PopupMenuButton<String>(
      tooltip: 'Switch notebook',
      position: PopupMenuPosition.over,
      onSelected: (value) async {
        if (value == _newValue) {
          await _createNotebook(context, ref);
        } else if (value == _manageValue) {
          if (context.mounted) {
            Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ManageNotebooksScreen(),
            ));
          }
        } else {
          await ref.read(selectedNotebookIdProvider.notifier).set(value);
        }
      },
      itemBuilder: (context) => [
        for (final nb in notebooks)
          PopupMenuItem(
            value: nb.id,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(nb.id == activeId
                  ? Icons.book
                  : Icons.book_outlined),
              title: Text(nb.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: nb.id == activeId ? const Icon(Icons.check) : null,
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _newValue,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add),
            title: Text('New notebook'),
          ),
        ),
        const PopupMenuItem(
          value: _manageValue,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Manage notebooks'),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.book_outlined, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _AppDrawer extends ConsumerWidget {
  const _AppDrawer({required this.email, required this.connected});

  final String email;
  final bool connected;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Build a zip of all notes (active + archived) as Markdown and hand it to the
  /// platform: share sheet on mobile, download on web.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
              ),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Text('Noteesek',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(connected ? Icons.cloud_done : Icons.cloud_off,
                            size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            connected ? email : 'Local only — not synced',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: const Icon(Icons.notes),
                    title: const Text('Notes'),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: const Text('Archive'),
                    onTap: () => _push(context, const ArchiveScreen()),
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Trash'),
                    onTap: () => _push(context, const TrashScreen()),
                  ),
                  const _LabelsSection(),
                ],
              ),
            ),
            const Divider(height: 1),
            if (!kIsWeb && !connected)
              ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('Connect to server'),
                subtitle: const Text('Enable sync across devices'),
                onTap: () => _push(context, const LoginScreen()),
              ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () => _push(context, const SettingsScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Drawer section listing the user's labels (tap to filter) plus an entry to
/// manage them. Only the "Edit labels" row shows when there are no labels yet.
class _LabelsSection extends ConsumerWidget {
  const _LabelsSection();

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(labelsProvider).asData?.value ?? const [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Labels',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
        ),
        for (final l in labels)
          ListTile(
            dense: true,
            leading: Icon(
              l.color.isEmpty ? Icons.label_outline : Icons.label,
              color: noteColorFor(context, l.color),
            ),
            title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _push(
              context,
              LabelNotesScreen(labelId: l.id, labelName: l.name),
            ),
          ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Edit labels'),
          onTap: () => _push(context, const ManageLabelsScreen()),
        ),
      ],
    );
  }
}

class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final filterCount = ref.watch(searchFiltersProvider).count;
    return SearchBar(
      controller: _ctrl,
      hintText: 'Search notes',
      leading: const Padding(
        padding: EdgeInsets.only(left: 8),
        child: Icon(Icons.search),
      ),
      trailing: [
        if (query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            tooltip: 'Clear',
            onPressed: () {
              _ctrl.clear();
              ref.read(searchQueryProvider.notifier).set('');
            },
          ),
        IconButton(
          tooltip: 'Filter',
          isSelected: filterCount > 0,
          icon: Badge(
            isLabelVisible: filterCount > 0,
            label: Text('$filterCount'),
            child: Icon(filterCount > 0
                ? Icons.filter_list
                : Icons.filter_list_outlined),
          ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => const _FilterSheet(),
          ),
        ),
      ],
      onChanged: (v) => ref.read(searchQueryProvider.notifier).set(v),
    );
  }
}

/// Bottom sheet of search filters: notebook scope, labels, color, note type,
/// and a has-image toggle. Edits the session-only [searchFiltersProvider].
class _FilterSheet extends ConsumerWidget {
  const _FilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchFiltersProvider);
    final notifier = ref.read(searchFiltersProvider.notifier);
    final labels = ref.watch(labelsProvider).asData?.value ?? const <LabelRow>[];
    final notebooks =
        ref.watch(notebooksProvider).asData?.value ?? const <NotebookRow>[];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Row(
              children: [
                Text('Filters',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (filters.isActive)
                  TextButton(
                    onPressed: notifier.clear,
                    child: const Text('Clear all'),
                  ),
              ],
            ),
            const SizedBox(height: 4),

            // Notebook scope.
            const _FilterLabel('Notebook'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('Current'),
                  selected: filters.notebookId == null,
                  onSelected: (_) => notifier.setNotebook(null),
                ),
                ChoiceChip(
                  label: const Text('All notebooks'),
                  selected: filters.notebookId == SearchFilters.allNotebooks,
                  onSelected: (_) =>
                      notifier.setNotebook(SearchFilters.allNotebooks),
                ),
                for (final nb in notebooks)
                  ChoiceChip(
                    label: Text(nb.name),
                    selected: filters.notebookId == nb.id,
                    onSelected: (_) => notifier.setNotebook(nb.id),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Labels (OR match).
            if (labels.isNotEmpty) ...[
              const _FilterLabel('Labels'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final l in labels)
                    FilterChip(
                      avatar: l.color.isEmpty
                          ? null
                          : CircleAvatar(
                              backgroundColor: noteSwatchFor(context, l.color)),
                      label: Text(l.name),
                      selected: filters.labelIds.contains(l.id),
                      onSelected: (_) => notifier.toggleLabel(l.id),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Color.
            const _FilterLabel('Color'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in kNoteColors)
                  GestureDetector(
                    onTap: () => notifier
                        .setColor(filters.color == c.key ? null : c.key),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: noteSwatchFor(context, c.key),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: filters.color == c.key
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).dividerColor,
                          width: filters.color == c.key ? 3 : 1,
                        ),
                      ),
                      child: c.key.isEmpty
                          ? const Icon(Icons.block, size: 18)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Type.
            const _FilterLabel('Type'),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Text'),
                  selected: filters.type == 'text',
                  onSelected: (s) => notifier.setType(s ? 'text' : null),
                ),
                ChoiceChip(
                  label: const Text('Checklist'),
                  selected: filters.type == 'checklist',
                  onSelected: (s) => notifier.setType(s ? 'checklist' : null),
                ),
              ],
            ),
            const SizedBox(height: 4),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Has image'),
              value: filters.hasImage,
              onChanged: notifier.setHasImage,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterLabel extends StatelessWidget {
  const _FilterLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

/// Wraps the notes area in a pull-to-refresh that triggers a sync. When
/// [onRefresh] is null (web — no sync engine) it's a passthrough.
class _SyncRefresh extends StatelessWidget {
  const _SyncRefresh({required this.onRefresh, required this.child});

  final Future<void> Function()? onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onRefresh == null) return child;
    return RefreshIndicator(onRefresh: onRefresh!, child: child);
  }
}

/// Makes a non-scrolling child (the empty/no-match states) fill the viewport and
/// scroll, so a pull-to-refresh gesture still registers over it.
class _ScrollableFill extends StatelessWidget {
  const _ScrollableFill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: child,
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off,
              size: 56, color: Theme.of(context).disabledColor),
          const SizedBox(height: 8),
          const Text('No matching notes'),
        ],
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Mobile, no server connected → nudge to connect for cross-device sync.
    final showConnect = !kIsWeb && !ref.watch(isAuthenticatedProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sticky_note_2_outlined,
                size: 72, color: theme.disabledColor),
            const SizedBox(height: 16),
            Text('No notes yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Tap the buttons below to add a note or checklist.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (showConnect) ...[
              const SizedBox(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.cloud_sync_outlined),
                label: const Text('Connect a server to sync'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
