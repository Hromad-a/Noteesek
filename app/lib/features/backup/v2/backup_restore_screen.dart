import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/notes_repository.dart';
import '../../../providers.dart';
import '../backup_service.dart' as backup;
import '../remote_backup_service.dart';
import 'backup_preview.dart';
import 'backup_v2.dart';
import 'backup_v2_import.dart';

/// Shared preview + restore screen for a v2 backup package (a downloaded backup
/// file or — later — a server snapshot). Reads only the manifest to show a
/// notebook-grouped, searchable, tri-state-selectable list, then either **adds**
/// the selected notes as copies or **replaces** the whole account/device.
/// Pops `true` once something was restored.
class BackupRestoreScreen extends ConsumerStatefulWidget {
  const BackupRestoreScreen(
      {super.key, required this.bytes, required this.sourceLabel});

  final Uint8List bytes;
  final String sourceLabel;

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
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Added $n note${n == 1 ? '' : 's'}')));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Import failed: $e');
    }
  }

  Future<void> _replace() async {
    final ok = await _confirmReplace();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final n = kIsWeb
          ? await RemoteBackupService(ref.read(pocketBaseProvider))
              .importV2(widget.bytes)
          : await backup.BackupService(ref.read(databaseProvider))
              .importV2(widget.bytes, ref.read(activeOwnerProvider));
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Restored $n note${n == 1 ? '' : 's'}')));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack('Restore failed: $e');
    }
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
        appBar: AppBar(title: const Text('Restore a backup')),
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
        title: const Text('Restore a backup'),
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
            child: Center(child: _HealthBadge(data: data)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Search notes',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          _SelectionBar(
            selected: _selected.length,
            onAll: () => setState(() => _selected.addAll(allNoteIds(data.groups))),
            onNone: () => setState(_selected.clear),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final g in groups) ..._groupTiles(g),
                const SizedBox(height: 8),
              ],
            ),
          ),
          _Footer(
            selectedCount: _selected.length,
            busy: _busy,
            notebookNames: _notebookNames,
            target: _targetNotebook,
            onTarget: (v) => setState(() => _targetNotebook = v),
            onAdd: _selected.isEmpty || _busy ? null : _add,
            onReplace: _busy ? null : _replace,
          ),
        ],
      ),
    );
  }

  List<Widget> _groupTiles(BackupNotebookGroup g) {
    final state = groupState(g, _selected);
    final open = _expanded.contains(g.notebookId);
    return [
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: () => setState(() =>
              open ? _expanded.remove(g.notebookId) : _expanded.add(g.notebookId)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                _TriBox(state: state, onTap: () => _toggleGroup(g)),
                const SizedBox(width: 10),
                Icon(g.notebookId.isEmpty ? Icons.folder_off_outlined : Icons.folder_outlined,
                    size: 20),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(g.name,
                        style: const TextStyle(fontWeight: FontWeight.w500))),
                Text('${g.notes.length}',
                    style: Theme.of(context).textTheme.bodySmall),
                Icon(open ? Icons.expand_less : Icons.expand_more,
                    color: Theme.of(context).colorScheme.outline),
              ],
            ),
          ),
        ),
      ),
      if (open)
        for (final n in g.notes) _noteTile(n),
    ];
  }

  Widget _noteTile(BackupNoteSummary n) {
    final sel = _selected.contains(n.id);
    Uint8List? thumb;
    if (n.thumb != null) thumb = _reader!.entryBytes(n.thumb!);
    return InkWell(
      onTap: () => _toggleNote(n.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
        child: Row(
          children: [
            Icon(sel ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20,
                color: sel ? Theme.of(context).colorScheme.primary : null),
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: thumb != null
                  ? Image.memory(thumb, width: 34, height: 34, fit: BoxFit.cover)
                  : Container(
                      width: 34,
                      height: 34,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(
                          n.type == 'checklist'
                              ? Icons.checklist
                              : Icons.notes,
                          size: 16,
                          color: Theme.of(context).colorScheme.outline),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.title.isEmpty ? 'Untitled' : n.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (n.snippet.isNotEmpty)
                    Text(n.snippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (n.damaged)
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: Theme.of(context).colorScheme.error),
          ],
        ),
      ),
    );
  }
}

class _TriBox extends StatelessWidget {
  const _TriBox({required this.state, required this.onTap});
  final TriState state;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    final icon = switch (state) {
      TriState.all => Icons.check_box,
      TriState.some => Icons.indeterminate_check_box,
      TriState.none => Icons.check_box_outline_blank,
    };
    return InkResponse(
      onTap: onTap,
      child: Icon(icon,
          size: 22,
          color: state == TriState.none
              ? Theme.of(context).colorScheme.outline
              : c),
    );
  }
}

class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.data});
  final BackupPreviewData data;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = data.healthy;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ok ? scheme.secondaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        ok ? 'verified' : '${data.damagedCount} damaged',
        style: TextStyle(
            fontSize: 12,
            color: ok ? scheme.onSecondaryContainer : scheme.onErrorContainer),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar(
      {required this.selected, required this.onAll, required this.onNone});
  final int selected;
  final VoidCallback onAll;
  final VoidCallback onNone;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
      child: Row(
        children: [
          Text('$selected selected',
              style: const TextStyle(fontWeight: FontWeight.w500)),
          const Spacer(),
          TextButton(onPressed: onAll, child: const Text('All')),
          TextButton(onPressed: onNone, child: const Text('None')),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.selectedCount,
    required this.busy,
    required this.notebookNames,
    required this.target,
    required this.onTarget,
    required this.onAdd,
    required this.onReplace,
  });
  final int selectedCount;
  final bool busy;
  final List<String> notebookNames;
  final String? target;
  final ValueChanged<String?> onTarget;
  final VoidCallback? onAdd;
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
          child: Column(
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
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: onAdd,
                      child: Text(busy ? '…' : 'Add $selectedCount to my notes'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onReplace,
                    style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                    child: const Text('Replace all…'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
