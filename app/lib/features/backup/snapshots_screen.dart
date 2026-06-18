import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../../ui/app_messenger.dart';
import 'snapshot_service.dart';

final snapshotServiceProvider = Provider<SnapshotService>(
    (ref) => SnapshotService(ref.watch(pocketBaseProvider)));

/// The account's snapshots, newest first. Auto-disposed so it re-fetches each
/// time the screen opens; invalidate to refresh after a backup/restore/delete.
final snapshotsListProvider =
    FutureProvider.autoDispose<List<SnapshotMeta>>((ref) {
  return ref.watch(snapshotServiceProvider).list();
});

final snapshotConfigProvider =
    FutureProvider.autoDispose<SnapshotConfig>((ref) {
  return ref.watch(snapshotServiceProvider).getConfig();
});

String _fmtDateTime(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $h:$m';
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Server-side version history: configure scheduled backups and browse /
/// preview / restore past snapshots. Requires a connected account (server).
class SnapshotsScreen extends ConsumerWidget {
  const SnapshotsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(isAuthenticatedProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Version history')),
      body: connected
          ? const _SnapshotsBody()
          : const _NeedsServer(),
    );
  }
}

class _NeedsServer extends StatelessWidget {
  const _NeedsServer();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Version history is stored on your server. Connect a server in '
              'Settings to enable scheduled backups.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapshotsBody extends ConsumerWidget {
  const _SnapshotsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listAsync = ref.watch(snapshotsListProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(snapshotsListProvider);
        ref.invalidate(snapshotConfigProvider);
        await ref.read(snapshotsListProvider.future);
      },
      child: ListView(
        children: [
          const _ConfigCard(),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Snapshots',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          listAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load snapshots: $e'),
            ),
            data: (snaps) => snaps.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No snapshots yet. They appear here once a '
                        'scheduled or manual backup runs.'),
                  )
                : Column(
                    children: [for (final s in snaps) _SnapshotTile(s)],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConfigCard extends ConsumerWidget {
  const _ConfigCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfgAsync = ref.watch(snapshotConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox(
        height: 120, child: Center(child: CircularProgressIndicator())),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Could not load settings: $e'),
      ),
      data: (cfg) => _ConfigEditor(initial: cfg),
    );
  }
}

class _ConfigEditor extends ConsumerStatefulWidget {
  const _ConfigEditor({required this.initial});
  final SnapshotConfig initial;
  @override
  ConsumerState<_ConfigEditor> createState() => _ConfigEditorState();
}

class _ConfigEditorState extends ConsumerState<_ConfigEditor> {
  late SnapshotConfig _cfg = widget.initial;
  bool _busy = false;

  Future<void> _save(SnapshotConfig next) async {
    setState(() => _cfg = next);
    try {
      await ref.read(snapshotServiceProvider).saveConfig(next);
    } catch (e) {
      if (mounted) showAppSnackBar('Could not save: $e');
    }
  }

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    try {
      await ref.read(snapshotServiceProvider).createNow();
      ref.invalidate(snapshotsListProvider);
      showAppSnackBar('Backup created');
    } catch (e) {
      showAppSnackBar('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Scheduled backups'),
          subtitle: const Text('Snapshot this account when it changes'),
          value: _cfg.enabled,
          onChanged: (v) => _save(_cfg.copyWith(enabled: v)),
        ),
        if (_cfg.enabled) ...[
          ListTile(
            title: const Text('Frequency'),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'daily', label: Text('Daily')),
                ButtonSegment(value: 'hourly', label: Text('Hourly')),
              ],
              selected: {_cfg.frequency},
              onSelectionChanged: (s) =>
                  _save(_cfg.copyWith(frequency: s.first)),
            ),
          ),
          ListTile(
            title: const Text('Keep for'),
            trailing: DropdownButton<int>(
              value: const [7, 14, 30, 60, 90].contains(_cfg.retentionDays)
                  ? _cfg.retentionDays
                  : 14,
              items: const [7, 14, 30, 60, 90]
                  .map((d) =>
                      DropdownMenuItem(value: d, child: Text('$d days')))
                  .toList(),
              onChanged: (d) =>
                  d == null ? null : _save(_cfg.copyWith(retentionDays: d)),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _backupNow,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.backup_outlined),
              label: const Text('Back up now'),
            ),
          ),
        ),
      ],
    );
  }
}

class _SnapshotTile extends ConsumerWidget {
  const _SnapshotTile(this.snap);
  final SnapshotMeta snap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reasonLabel = switch (snap.reason) {
      'manual' => 'Manual',
      'pre-restore' => 'Before restore',
      _ => 'Auto',
    };
    return ListTile(
      leading: const Icon(Icons.history),
      title: Text(_fmtDateTime(snap.createdAt)),
      subtitle: Text(
          '$reasonLabel · ${snap.noteCount} notes · ${_fmtSize(snap.byteSize)}'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete snapshot',
        onPressed: () async {
          final yes = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Delete snapshot?'),
              content: Text('Delete the snapshot from '
                  '${_fmtDateTime(snap.createdAt)}? This cannot be undone.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Delete')),
              ],
            ),
          );
          if (yes != true) return;
          try {
            await ref.read(snapshotServiceProvider).delete(snap.id);
            ref.invalidate(snapshotsListProvider);
          } catch (e) {
            showAppSnackBar('Delete failed: $e');
          }
        },
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SnapshotPreviewScreen(snap: snap),
      )),
    );
  }
}

/// Read-only preview of a snapshot's notes, with whole-account or per-note
/// restore.
class SnapshotPreviewScreen extends ConsumerStatefulWidget {
  const SnapshotPreviewScreen({super.key, required this.snap});
  final SnapshotMeta snap;

  @override
  ConsumerState<SnapshotPreviewScreen> createState() =>
      _SnapshotPreviewScreenState();
}

class _SnapshotPreviewScreenState
    extends ConsumerState<SnapshotPreviewScreen> {
  final _selected = <String>{};
  bool _restoring = false;

  Future<void> _restore(String mode) async {
    final noteIds = _selected.toList();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(mode == 'replace'
            ? 'Replace everything?'
            : 'Restore ${noteIds.length} '
                '${noteIds.length == 1 ? 'note' : 'notes'}?'),
        content: Text(mode == 'replace'
            ? 'Your account will be made to match this snapshot exactly. Notes '
                'that don\'t exist in it are moved to Trash. A safety backup of '
                'the current state is taken first, so this is reversible.'
            : 'The selected notes are reverted to their version in this '
                'snapshot. Other notes are left untouched. A safety backup is '
                'taken first.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _restoring = true);
    try {
      await ref
          .read(snapshotServiceProvider)
          .restore(widget.snap.id, mode: mode, noteIds: noteIds);
      // The restore wrote on the server with fresh timestamps; on mobile, pull
      // it down so the local DB converges (web reads the server directly).
      if (!kIsWeb) {
        await ref.read(syncControllerProvider.notifier).syncNow(manual: true);
      }
      ref.invalidate(snapshotsListProvider);
      if (mounted) {
        showAppSnackBar('Restored');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showAppSnackBar('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contentsAsync =
        ref.watch(_snapshotContentsProvider(widget.snap.id));
    return Scaffold(
      appBar: AppBar(
        title: Text('Snapshot · ${_fmtDateTime(widget.snap.createdAt)}'),
      ),
      body: contentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not open snapshot: $e'),
        ),
        data: (contents) => _restoring
            ? const Center(child: CircularProgressIndicator())
            : _PreviewList(
                notes: contents.notes,
                selected: _selected,
                onToggle: (id) => setState(() =>
                    _selected.contains(id) ? _selected.remove(id) : _selected.add(id)),
              ),
      ),
      bottomNavigationBar: contentsAsync.maybeWhen(
        data: (_) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _restoring ? null : () => _restore('replace'),
                    child: const Text('Replace everything'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: (_restoring || _selected.isEmpty)
                        ? null
                        : () => _restore('notes'),
                    child: Text(_selected.isEmpty
                        ? 'Restore selected'
                        : 'Restore ${_selected.length} selected'),
                  ),
                ),
              ],
            ),
          ),
        ),
        orElse: () => const SizedBox.shrink(),
      ),
    );
  }
}

final _snapshotContentsProvider =
    FutureProvider.autoDispose.family<SnapshotContents, String>((ref, id) {
  return ref.watch(snapshotServiceProvider).preview(id);
});

class _PreviewList extends StatelessWidget {
  const _PreviewList({
    required this.notes,
    required this.selected,
    required this.onToggle,
  });

  final List<SnapshotNote> notes;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) {
      return const Center(child: Text('This snapshot has no active notes.'));
    }
    return ListView.builder(
      itemCount: notes.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Tap notes to select them for a partial restore, or use '
              '“Replace everything”.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final n = notes[i - 1];
        final subtitleBits = <String>[
          if (n.type == 'checklist') '${n.items.length} items',
          if (n.imageCount > 0)
            '${n.imageCount} ${n.imageCount == 1 ? 'image' : 'images'}',
        ];
        final snippet = n.type == 'checklist'
            ? n.items.map((e) => '${e.checked ? '☑' : '☐'} ${e.content}').join('  ')
            : n.body.trim();
        return CheckboxListTile(
          value: selected.contains(n.id),
          onChanged: (_) => onToggle(n.id),
          title: Text(n.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [if (subtitleBits.isNotEmpty) subtitleBits.join(' · '), snippet]
                .where((s) => s.isNotEmpty)
                .join('\n'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: snippet.isNotEmpty,
        );
      },
    );
  }
}
