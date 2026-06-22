import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../../l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../../ui/app_messenger.dart';
import '../../ui/web_centered.dart';
import 'snapshot_service.dart';
import 'v2/backup_preview.dart';
import 'v2/backup_preview_view.dart';

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

// The daily-snapshot hour is stored in UTC (the server cron compares UTC hours);
// the picker shows the user's local time, converting with the device's current
// offset. Whole-hour offsets convert cleanly; the rare half-hour zones round.
int _localHourFromUtc(int utc) =>
    ((utc + DateTime.now().timeZoneOffset.inHours) % 24 + 24) % 24;
int _utcHourFromLocal(int local) =>
    ((local - DateTime.now().timeZoneOffset.inHours) % 24 + 24) % 24;
String _fmtHour(int h) => '${h.toString().padLeft(2, '0')}:00';

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
      appBar: AppBar(title: Text(context.l10n.versionHistory)),
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
            child: Text(context.l10n.snapshotsHeader,
                style: Theme.of(context).textTheme.titleSmall),
          ),
          listAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(context.l10n.couldNotLoadSnapshots('$e')),
            ),
            data: (snaps) => snaps.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(context.l10n.noSnapshotsYet),
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
        child: Text(context.l10n.couldNotLoadSettings('$e')),
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
    final l10n = context.l10n;
    setState(() => _cfg = next);
    try {
      await ref.read(snapshotServiceProvider).saveConfig(next);
    } catch (e) {
      if (mounted) showAppSnackBar(l10n.couldNotSave('$e'));
    }
  }

  Future<void> _backupNow() async {
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      await ref.read(snapshotServiceProvider).createNow();
      ref.invalidate(snapshotsListProvider);
      showAppSnackBar(l10n.backupCreated);
    } catch (e) {
      showAppSnackBar(l10n.backupFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          title: Text(context.l10n.scheduledBackups),
          subtitle: Text(context.l10n.scheduledBackupsSub),
          value: _cfg.enabled,
          onChanged: (v) => _save(_cfg.copyWith(enabled: v)),
        ),
        if (_cfg.enabled) ...[
          ListTile(
            title: Text(context.l10n.frequency),
            trailing: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'daily', label: Text(context.l10n.daily)),
                ButtonSegment(value: 'hourly', label: Text(context.l10n.hourly)),
              ],
              selected: {_cfg.frequency},
              onSelectionChanged: (s) =>
                  _save(_cfg.copyWith(frequency: s.first)),
            ),
          ),
          if (_cfg.frequency == 'daily')
            ListTile(
              title: Text(context.l10n.runAt),
              subtitle: Text(context.l10n.yourLocalTime),
              trailing: DropdownButton<int>(
                value: _localHourFromUtc(_cfg.hour),
                items: [
                  for (var h = 0; h < 24; h++)
                    DropdownMenuItem(value: h, child: Text(_fmtHour(h))),
                ],
                onChanged: (h) => h == null
                    ? null
                    : _save(_cfg.copyWith(hour: _utcHourFromLocal(h))),
              ),
            ),
          ListTile(
            title: Text(context.l10n.keepFor),
            trailing: DropdownButton<int>(
              value: const [7, 14, 30, 60, 90].contains(_cfg.retentionDays)
                  ? _cfg.retentionDays
                  : 14,
              items: const [7, 14, 30, 60, 90]
                  .map((d) =>
                      DropdownMenuItem(value: d, child: Text(context.l10n.daysCount(d))))
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
              label: Text(context.l10n.backUpNow),
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
      'manual' => context.l10n.snapReasonManual,
      'pre-restore' => context.l10n.snapReasonBeforeRestore,
      _ => context.l10n.snapReasonAuto,
    };
    return ListTile(
      leading: const Icon(Icons.history),
      title: Text(_fmtDateTime(snap.createdAt)),
      subtitle: Text(
          '$reasonLabel · ${context.l10n.notesAndSize(snap.noteCount, _fmtSize(snap.byteSize))}'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: context.l10n.deleteSnapshot,
        onPressed: () async {
          final l10n = context.l10n;
          final yes = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(context.l10n.deleteSnapshotTitle),
              content: Text(context.l10n.deleteSnapshotBody(_fmtDateTime(snap.createdAt))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: Text(context.l10n.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: Text(context.l10n.delete)),
              ],
            ),
          );
          if (yes != true) return;
          try {
            await ref.read(snapshotServiceProvider).delete(snap.id);
            ref.invalidate(snapshotsListProvider);
          } catch (e) {
            showAppSnackBar(l10n.deleteFailed('$e'));
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
  final _expanded = <String>{};
  String _query = '';
  bool _restoring = false;
  bool _seeded = false; // default-select everything once the contents load

  void _toggleNote(String id) => setState(() {
        _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
      });

  void _toggleGroup(BackupNotebookGroup g) => setState(() {
        final ids = g.notes.map((n) => n.id);
        if (groupState(g, _selected) == TriState.all) {
          _selected.removeAll(ids);
        } else {
          _selected.addAll(ids);
        }
      });

  Future<void> _restore(String mode) async {
    final l10n = context.l10n;
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
              child: Text(context.l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(context.l10n.restore)),
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
        showAppSnackBar(l10n.restoredOk);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showAppSnackBar(l10n.restoreFailed('$e'));
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
        title: Text(context.l10n.snapshotTitle(_fmtDateTime(widget.snap.createdAt))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.l10n.notesAndSize(
                    widget.snap.noteCount, _fmtSize(widget.snap.byteSize)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(
                child: BackupHealthBadge(healthy: true, damagedCount: 0)),
          ),
        ],
      ),
      body: contentsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(context.l10n.couldNotOpenSnapshot('$e')),
        ),
        data: (contents) => _restoring
            ? const Center(child: CircularProgressIndicator())
            : _body(contents),
      ),
    );
  }

  Widget _body(SnapshotContents contents) {
    final all = contents.toPreviewGroups();
    if (!_seeded) {
      _seeded = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _selected.addAll(allNoteIds(all));
          if (all.isNotEmpty) _expanded.add(all.first.notebookId);
        });
      });
    }
    if (all.isEmpty) {
      return Center(child: Text(context.l10n.snapshotNoActiveNotes));
    }
    final scheme = Theme.of(context).colorScheme;
    final groups = filterGroups(all, _query);
    return WebCentered(
      child: Column(
        children: [
          BackupSearchField(onChanged: (v) => setState(() => _query = v)),
          BackupSelectionBar(
            selected: _selected.length,
            onAll: () => setState(() => _selected.addAll(allNoteIds(all))),
            onNone: () => setState(_selected.clear),
          ),
          Expanded(
            child: BackupPreviewList(
              groups: groups,
              selected: _selected,
              expanded: _expanded,
              onToggleNote: _toggleNote,
              onToggleGroup: _toggleGroup,
              onToggleExpand: (id) => setState(() => _expanded.contains(id)
                  ? _expanded.remove(id)
                  : _expanded.add(id)),
            ),
          ),
          Material(
            elevation: 2,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: (_restoring || _selected.isEmpty)
                            ? null
                            : () => _restore('notes'),
                        child: Text(context.l10n.restoreSelectedCount(_selected.length)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _restoring ? null : () => _restore('replace'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error),
                      child: Text(context.l10n.replaceAll),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final _snapshotContentsProvider =
    FutureProvider.autoDispose.family<SnapshotContents, String>((ref, id) {
  return ref.watch(snapshotServiceProvider).preview(id);
});
