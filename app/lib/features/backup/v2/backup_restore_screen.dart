import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/notes_repository.dart';
import '../../../providers.dart';
import '../../../ui/web_centered.dart';
import '../backup_service.dart' as backup;
import '../remote_backup_service.dart';
import 'backup_preview.dart';
import 'backup_preview_view.dart';
import 'backup_v2.dart';
import 'backup_v2_import.dart';

/// Shared preview + restore screen for a v2 backup package (a downloaded backup
/// file or — later — a server snapshot). Reads only the manifest to show a
/// notebook-grouped, searchable, tri-state-selectable list, then either **adds**
/// the selected notes as copies or **replaces** the whole account/device.
/// Pops `true` once something was restored.
class BackupRestoreScreen extends ConsumerStatefulWidget {
  const BackupRestoreScreen({
    super.key,
    required this.bytes,
    required this.sourceLabel,
    this.title = 'Restore a backup',
    this.copiesOnly = false,
  });

  final Uint8List bytes;
  final String sourceLabel;

  /// App-bar title (e.g. "Import notes" when the source is a Markdown import).
  final String title;

  /// When true the source is a copy-only import (e.g. Markdown): notes come in
  /// as new copies into a chosen notebook. When false (a backup file) restore is
  /// **by id** — "Restore selected" + "Replace everything" — so it never
  /// duplicates an existing note.
  final bool copiesOnly;

  @override
  ConsumerState<BackupRestoreScreen> createState() =>
      _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends ConsumerState<BackupRestoreScreen> {
  BackupV2Reader? _reader;
  BackupPreviewData? _data;
  Object? _error;

  final _selected = <String>{};
  final _expanded = <String>{};
  String _query = '';
  bool _busy = false;

  /// null = keep each note's original notebook; '' = no notebook; else a name.
  String? _targetNotebook;
  List<String> _notebookNames = const [];

  @override
  void initState() {
    super.initState();
    try {
      final r = BackupV2Reader.read(widget.bytes);
      final d = buildBackupPreview(r);
      _reader = r;
      _data = d;
      _selected.addAll(allNoteIds(d.groups)); // default: everything selected
      if (d.groups.isNotEmpty) _expanded.add(d.groups.first.notebookId);
    } catch (e) {
      _error = e;
    }
    _loadNotebooks();
  }

  Future<void> _loadNotebooks() async {
    try {
      final nbs = await ref.read(notesRepositoryProvider).watchNotebooks().first;
      if (mounted) setState(() => _notebookNames = nbs.map((n) => n.name).toList());
    } catch (_) {/* picker just shows the basics */}
  }

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

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      final n = await addNotesFromBackup(
        ref.read(notesRepositoryProvider),
        _reader!,
        selectedNoteIds: _selected,
        targetNotebookName: _targetNotebook,
      );
      _done(n, 'Added');
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Import failed: $e');
    }
  }

  /// Restore only the selected notes, by id (no duplicates).
  Future<void> _restoreSelected() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restore ${_selected.length} '
            '${_selected.length == 1 ? 'note' : 'notes'}?'),
        content: const Text(
            'The selected notes will be replaced with the version from this '
            'backup. Your other notes are left untouched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = kIsWeb
          ? await RemoteBackupService(ref.read(pocketBaseProvider))
              .importV2(widget.bytes, selectedNoteIds: _selected)
          : await backup.BackupService(ref.read(databaseProvider)).importV2(
              widget.bytes, ref.read(activeOwnerProvider),
              selectedNoteIds: _selected);
      _done(n, 'Restored');
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Restore failed: $e');
    }
  }

  /// Make the account match the whole backup (by id; absent notes → Trash).
  Future<void> _replace() async {
    final ok = await _confirmReplace();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = kIsWeb
          ? await RemoteBackupService(ref.read(pocketBaseProvider))
              .importV2(widget.bytes, mirror: true)
          : await backup.BackupService(ref.read(databaseProvider)).importV2(
              widget.bytes, ref.read(activeOwnerProvider),
              mirror: true);
      _done(n, 'Restored');
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Restore failed: $e');
    }
  }

  void _done(int n, String verb) {
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text('$verb $n note${n == 1 ? '' : 's'}')));
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<bool?> _confirmReplace() {
    final ctrl = TextEditingController();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Replace everything?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your notes will become exactly this backup. Notes '
                  'not in it move to Trash. This cannot be undone.'),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Type REPLACE to confirm'),
                onChanged: (_) => setLocal(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: ctrl.text.trim().toUpperCase() == 'REPLACE'
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Replace'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text("This isn't a readable backup.\n$_error",
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final data = _data!;
    final groups = filterGroups(data.groups, _query);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${widget.sourceLabel} · ${data.noteCount} notes · '
                '${data.imageCount} images',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
                child: BackupHealthBadge(
                    healthy: data.healthy, damagedCount: data.damagedCount)),
          ),
        ],
      ),
      body: WebCentered(
        child: Column(
        children: [
          BackupSearchField(onChanged: (v) => setState(() => _query = v)),
          BackupSelectionBar(
            selected: _selected.length,
            onAll: () => setState(() => _selected.addAll(allNoteIds(data.groups))),
            onNone: () => setState(_selected.clear),
          ),
          Expanded(
            child: BackupPreviewList(
              groups: groups,
              selected: _selected,
              expanded: _expanded,
              thumbForPath: (p) => _reader!.entryBytes(p),
              onToggleNote: _toggleNote,
              onToggleGroup: _toggleGroup,
              onToggleExpand: (id) => setState(() =>
                  _expanded.contains(id) ? _expanded.remove(id) : _expanded.add(id)),
            ),
          ),
          _Footer(
            selectedCount: _selected.length,
            busy: _busy,
            copiesOnly: widget.copiesOnly,
            notebookNames: _notebookNames,
            target: _targetNotebook,
            onTarget: (v) => setState(() => _targetNotebook = v),
            onAdd: _selected.isEmpty || _busy ? null : _add,
            onRestoreSelected:
                _selected.isEmpty || _busy ? null : _restoreSelected,
            onReplace: _busy ? null : _replace,
          ),
        ],
      )),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.selectedCount,
    required this.busy,
    required this.copiesOnly,
    required this.notebookNames,
    required this.target,
    required this.onTarget,
    required this.onAdd,
    required this.onRestoreSelected,
    required this.onReplace,
  });
  final int selectedCount;
  final bool busy;
  final bool copiesOnly;
  final List<String> notebookNames;
  final String? target;
  final ValueChanged<String?> onTarget;
  final VoidCallback? onAdd;
  final VoidCallback? onRestoreSelected;
  final VoidCallback? onReplace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: copiesOnly ? _copies(context) : _restore(scheme),
        ),
      ),
    );
  }

  // Copy-only import (Markdown/Keep): new notes into a chosen notebook.
  Widget _copies(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('Add into', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: target,
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Keep original notebook')),
                    const DropdownMenuItem(
                        value: '', child: Text('No notebook')),
                    for (final n in notebookNames)
                      DropdownMenuItem(value: n, child: Text(n)),
                  ],
                  onChanged: busy ? null : onTarget,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: onAdd,
              child: Text(busy ? '…' : 'Add $selectedCount to my notes'),
            ),
          ),
        ],
      );

  // Backup-file restore: by id (no duplicates) — selected, or the whole thing.
  Widget _restore(ColorScheme scheme) => Row(
        children: [
          Expanded(
            child: FilledButton.tonal(
              onPressed: onRestoreSelected,
              child: Text(busy ? '…' : 'Restore $selectedCount selected'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onReplace,
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Replace all…'),
          ),
        ],
      );
}
