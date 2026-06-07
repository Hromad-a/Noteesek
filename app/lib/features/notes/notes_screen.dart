import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../auth/login_screen.dart';
import '../auth/settings_screen.dart';
import '../export/export_delivery.dart';
import '../export/export_service.dart';
import 'archive_screen.dart';
import 'label_notes_screen.dart';
import 'manage_labels_screen.dart';
import 'note_card.dart';
import 'note_editor_screen.dart';
import 'trash_screen.dart';

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
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(activeNotesProvider);
    final pb = ref.watch(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';
    final connected = ref.watch(isAuthenticatedProvider);
    final sync = kIsWeb ? null : ref.watch(syncControllerProvider);

    return Scaffold(
      drawer: _AppDrawer(email: email, connected: connected),
      appBar: AppBar(
        title: const Text('Notes'),
        actions: [
          if (sync != null) ...[
            if (connected && !sync.reachable && !sync.syncing)
              IconButton(
                tooltip: 'Server not responding — tap to retry',
                icon: Icon(Icons.cloud_off,
                    color: Theme.of(context).colorScheme.error),
                onPressed: () => _manualSync(context, ref),
              )
            else if (sync.syncing)
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
                tooltip: connected ? 'Sync now' : 'Connect a server to sync',
                icon: const Icon(Icons.sync),
                onPressed: connected ? () => _manualSync(context, ref) : null,
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
              child: notesAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('Error: $e')),
                data: (notes) {
                  if (notes.isEmpty) {
                    final searching =
                        ref.watch(searchQueryProvider).trim().isNotEmpty;
                    return searching
                        ? const _NoMatches()
                        : const _EmptyState();
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
                            );
                          },
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
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
  Future<void> _exportNotes(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Preparing export…')));
    try {
      final bytes = await NoteExportService(ref.read(notesRepositoryProvider))
          .buildZip();
      if (bytes == null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('No notes to export')));
        return;
      }
      await deliverExport(bytes, exportFileName());
      messenger.hideCurrentSnackBar();
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

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
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('Export notes'),
                    subtitle: const Text('Download all notes as Markdown'),
                    onTap: () => _exportNotes(context, ref),
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
            leading: const Icon(Icons.label_outline),
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
      ],
      onChanged: (v) => ref.read(searchQueryProvider.notifier).set(v),
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
