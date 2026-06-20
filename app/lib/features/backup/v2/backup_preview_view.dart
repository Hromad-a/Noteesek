import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'backup_preview.dart';

/// Shared presentational pieces for the restore preview, used by both the
/// backup-file restore screen and the version-history (snapshot) restore screen
/// so the two look identical. All state (selection/search/expanded) lives in the
/// hosting screen; these widgets are stateless and callback-driven.

/// The notebook-grouped, tri-state-selectable list of notes.
class BackupPreviewList extends StatelessWidget {
  const BackupPreviewList({
    super.key,
    required this.groups,
    required this.selected,
    required this.expanded,
    required this.onToggleNote,
    required this.onToggleGroup,
    required this.onToggleExpand,
    this.thumbForPath,
  });

  final List<BackupNotebookGroup> groups;
  final Set<String> selected;
  final Set<String> expanded;
  final ValueChanged<String> onToggleNote;
  final ValueChanged<BackupNotebookGroup> onToggleGroup;
  final ValueChanged<String> onToggleExpand;

  /// Resolves a note's `thumbs/<sha>.<ext>` path to bytes (backup files only;
  /// snapshots have no client-side thumbnails → leave null).
  final Uint8List? Function(String path)? thumbForPath;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        for (final g in groups) ..._groupTiles(context, g),
        const SizedBox(height: 8),
      ],
    );
  }

  List<Widget> _groupTiles(BuildContext context, BackupNotebookGroup g) {
    final scheme = Theme.of(context).colorScheme;
    final empty = g.notes.isEmpty;
    final state = groupState(g, selected);
    final open = expanded.contains(g.notebookId);
    return [
      Material(
        color: scheme.surfaceContainerHighest,
        child: InkWell(
          // Nothing to expand/select in an empty notebook — it's shown for
          // visibility (it's restored regardless).
          onTap: empty ? null : () => onToggleExpand(g.notebookId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                if (empty)
                  const SizedBox(width: 22)
                else
                  BackupTriBox(state: state, onTap: () => onToggleGroup(g)),
                const SizedBox(width: 10),
                Icon(
                    g.notebookId.isEmpty
                        ? Icons.folder_off_outlined
                        : Icons.folder_outlined,
                    size: 20,
                    color: empty ? scheme.outline : null),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(g.name,
                        style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: empty ? scheme.outline : null))),
                if (empty)
                  Text('empty', style: Theme.of(context).textTheme.bodySmall)
                else ...[
                  Text('${g.notes.length}',
                      style: Theme.of(context).textTheme.bodySmall),
                  Icon(open ? Icons.expand_less : Icons.expand_more,
                      color: scheme.outline),
                ],
              ],
            ),
          ),
        ),
      ),
      if (open)
        for (final n in g.notes) _noteTile(context, n),
    ];
  }

  Widget _noteTile(BuildContext context, BackupNoteSummary n) {
    final scheme = Theme.of(context).colorScheme;
    final sel = selected.contains(n.id);
    Uint8List? thumb;
    if (n.thumb != null && thumbForPath != null) thumb = thumbForPath!(n.thumb!);
    return InkWell(
      onTap: () => onToggleNote(n.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
        child: Row(
          children: [
            Icon(sel ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20, color: sel ? scheme.primary : null),
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: thumb != null
                  ? Image.memory(thumb, width: 34, height: 34, fit: BoxFit.cover)
                  : Container(
                      width: 34,
                      height: 34,
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                          n.type == 'checklist'
                              ? Icons.checklist
                              : Icons.notes,
                          size: 16,
                          color: scheme.outline),
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
              Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
          ],
        ),
      ),
    );
  }
}

/// A tri-state (none / some / all) selection box for a notebook group header.
class BackupTriBox extends StatelessWidget {
  const BackupTriBox({super.key, required this.state, required this.onTap});
  final TriState state;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (state) {
      TriState.all => Icons.check_box,
      TriState.some => Icons.indeterminate_check_box,
      TriState.none => Icons.check_box_outline_blank,
    };
    return InkResponse(
      onTap: onTap,
      child: Icon(icon,
          size: 22,
          color: state == TriState.none ? scheme.outline : scheme.primary),
    );
  }
}

/// "N selected" with All / None shortcuts.
class BackupSelectionBar extends StatelessWidget {
  const BackupSelectionBar(
      {super.key,
      required this.selected,
      required this.onAll,
      required this.onNone});
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

/// A search box matching the restore preview.
class BackupSearchField extends StatelessWidget {
  const BackupSearchField({super.key, required this.onChanged});
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        decoration: const InputDecoration(
          isDense: true,
          prefixIcon: Icon(Icons.search),
          hintText: 'Search notes',
          border: OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// A small "verified" / "N damaged" health pill for the app bar.
class BackupHealthBadge extends StatelessWidget {
  const BackupHealthBadge(
      {super.key, required this.healthy, required this.damagedCount});
  final bool healthy;
  final int damagedCount;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: healthy ? scheme.secondaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        healthy ? 'verified' : '$damagedCount damaged',
        style: TextStyle(
            fontSize: 12,
            color: healthy
                ? scheme.onSecondaryContainer
                : scheme.onErrorContainer),
      ),
    );
  }
}
