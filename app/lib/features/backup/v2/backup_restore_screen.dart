import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../../l10n/l10n.dart';
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
    this.title,
    this.copiesOnly = false,
  });

  final Uint8List bytes;
  final String sourceLabel;

  /// App-bar title (e.g. "Import notes" when the source is a Markdown import).
  /// Null falls back to a localized "Restore a backup".
  final String? title;

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
    final l10n = context.l10n;
    setState(() => _busy = true);
    try {
      final n = await addNotesFromBackup(
        ref.read(notesRepositoryProvider),
        _reader!,
        selectedNoteIds: _selected,
        targetNotebookName: _targetNotebook,
      );
      _done(l10n.addedNotesCount(n));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack(l10n.importFailed('$e'));
    }
  }

  /// Restore only the selected notes, by id (no duplicates).
  Future<void> _restoreSelected() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.restoreSelectedTitle(_selected.length)),
        content: Text(l10n.restoreSelectedBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.restore)),
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
      _done(l10n.restoredNotesCount(n));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack(l10n.restoreFailed('$e'));
    }
  }

  /// Make the account match the whole backup (by id; absent notes → Trash).
  Future<void> _replace() async {
    final l10n = context.l10n;
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
      _done(l10n.restoredNotesCount(n));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack(l10n.restoreFailed('$e'));
    }
  }

  void _done(String message) {
    if (!mounted) return;
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
          title: Text(context.l10n.replaceEverythingTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.replaceEverythingBody),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: context.l10n.typeReplaceToConfirm),
                onChanged: (_) => setLocal(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(context.l10n.cancel)),
            FilledButton(
              onPressed: ctrl.text.trim().toUpperCase() == 'REPLACE'
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(context.l10n.replace),
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
        appBar: AppBar(title: Text(widget.title ?? context.l10n.restoreABackup)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text("${context.l10n.notReadableBackup}\n$_error",
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final data = _data!;
    final groups = filterGroups(data.groups, _query);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? context.l10n.restoreABackup),
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
          child: copiesOnly ? _copies(context) : _restore(context, scheme),
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
              Text(context.l10n.addInto, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: target,
                  items: [
                    DropdownMenuItem(value: null, child: Text(context.l10n.keepOriginalNotebook)),
                    DropdownMenuItem(value: '', child: Text(context.l10n.noNotebook)),
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
              child: Text(busy ? '…' : context.l10n.addCountToMyNotes(selectedCount)),
            ),
          ),
        ],
      );

  // Backup-file restore: by id (no duplicates) — selected, or the whole thing.
  Widget _restore(BuildContext context, ColorScheme scheme) => Row(
        children: [
          Expanded(
            child: FilledButton.tonal(
              onPressed: onRestoreSelected,
              child: Text(busy ? '…' : context.l10n.restoreSelectedCount(selectedCount)),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onReplace,
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            child: Text(context.l10n.replaceAll),
          ),
        ],
      );
}
