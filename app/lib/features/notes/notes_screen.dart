import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../config/app_config.dart';
import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../auth/login_screen.dart';
import 'archive_screen.dart';
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

  /// Trigger a manual sync and show a bottom message describing the result.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(activeNotesProvider);
    final pb = ref.watch(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';
    final connected = ref.watch(isAuthenticatedProvider);
    final sync = ref.watch(syncControllerProvider);

    return Scaffold(
      drawer: _AppDrawer(email: email, connected: connected),
      appBar: AppBar(
        title: const Text('Notes'),
        actions: [
          if (connected && !sync.reachable && !sync.syncing)
            IconButton(
              // Server unreachable — non-fatal; tap to retry.
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
              // Disabled (greyed) until a server is connected.
              tooltip: connected ? 'Sync now' : 'Connect a server to sync',
              icon: const Icon(Icons.sync),
              onPressed:
                  connected ? () => _manualSync(context, ref) : null,
            ),
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
                        final NoteRow note = notes[i];
                        return NoteCard(
                            note: note, onTap: () => _open(context, note.id));
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
    Navigator.of(context).pop(); // close drawer
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
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
            const Spacer(),
            const Divider(height: 1),
            if (connected)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Disconnect'),
                subtitle: const Text('Stop syncing; notes stay on device'),
                onTap: () async {
                  Navigator.of(context).pop();
                  ref.read(pocketBaseProvider).authStore.clear();
                  await ref
                      .read(activeOwnerProvider.notifier)
                      .set(AppConfig.localOwner);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('Connect to server'),
                subtitle: const Text('Enable sync across devices'),
                onTap: () => _push(context, const LoginScreen()),
              ),
          ],
        ),
      ),
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
      leading: const Icon(Icons.search),
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
