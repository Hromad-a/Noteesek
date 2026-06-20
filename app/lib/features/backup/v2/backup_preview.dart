import 'backup_v2.dart';

/// Pure preview model for a v2 backup: turns a [BackupV2Reader]'s manifest into
/// notebook-grouped note summaries (no note bodies/images read), and provides
/// search + tri-state group selection helpers. The widget layer holds the
/// mutable selection `Set<String>` and renders this. Unit-testable (no Flutter).

enum TriState { none, some, all }

class BackupNoteSummary {
  BackupNoteSummary({
    required this.id,
    required this.title,
    required this.snippet,
    required this.type,
    required this.notebookId,
    required this.thumb,
    required this.damaged,
  });
  final String id;
  final String title;
  final String snippet;
  final String type; // text | checklist
  final String notebookId;
  final String? thumb; // `thumbs/<sha>.<ext>` path, or null
  final bool damaged; // its notes/<id>.json failed verification
}

class BackupNotebookGroup {
  BackupNotebookGroup({required this.notebookId, required this.name, required this.notes});
  final String notebookId; // '' = no notebook
  final String name;
  final List<BackupNoteSummary> notes;
}

class BackupPreviewData {
  BackupPreviewData({
    required this.groups,
    required this.noteCount,
    required this.imageCount,
    required this.damagedCount,
    required this.exportedAt,
    required this.app,
  });
  final List<BackupNotebookGroup> groups;
  final int noteCount; // selectable (non-trashed) notes
  final int imageCount;
  final int damagedCount;
  final DateTime? exportedAt;
  final String app;

  bool get healthy => damagedCount == 0;
}

/// Builds the preview from a reader. Trashed notes are excluded (they aren't
/// selectable for an Add); a whole-file Replace restores them regardless.
BackupPreviewData buildBackupPreview(BackupV2Reader r) {
  final nbNameById = {
    for (final nb in r.notebooks)
      nb['id'] as String: (nb['name'] as String? ?? '').trim()
  };
  final damagedPaths = r.damagedEntries().toSet();

  final byNotebook = <String, List<BackupNoteSummary>>{};
  var images = 0;
  for (final n in r.notes) {
    if (n['deleted'] == true) continue;
    final atts = (n['attachments'] as List?) ?? const [];
    if (atts.isNotEmpty) images += atts.length;
    final nbId = (n['notebookId'] as String?) ?? '';
    final hasName = (nbNameById[nbId] ?? '').isNotEmpty;
    final key = hasName ? nbId : ''; // unknown/empty notebook → "No notebook"
    final id = n['id'] as String;
    (byNotebook[key] ??= []).add(BackupNoteSummary(
      id: id,
      title: (n['title'] as String? ?? '').trim(),
      snippet: n['snippet'] as String? ?? '',
      type: n['type'] as String? ?? 'text',
      notebookId: key,
      thumb: atts.isEmpty ? null : (atts.first as Map)['thumb'] as String?,
      damaged: damagedPaths.contains('notes/$id.json'),
    ));
  }

  // Named notebooks first (alphabetical), "No notebook" last.
  final groups = <BackupNotebookGroup>[];
  final namedKeys = byNotebook.keys.where((k) => k.isNotEmpty).toList()
    ..sort((a, b) => nbNameById[a]!.toLowerCase().compareTo(nbNameById[b]!.toLowerCase()));
  for (final k in namedKeys) {
    groups.add(BackupNotebookGroup(
        notebookId: k, name: nbNameById[k]!, notes: byNotebook[k]!));
  }
  if (byNotebook.containsKey('')) {
    groups.add(BackupNotebookGroup(
        notebookId: '', name: 'No notebook', notes: byNotebook['']!));
  }

  DateTime? exportedAt;
  final ts = r.manifest['exportedAt'];
  if (ts is String) exportedAt = DateTime.tryParse(ts);

  return BackupPreviewData(
    groups: groups,
    noteCount: byNotebook.values.fold(0, (s, l) => s + l.length),
    imageCount: images,
    damagedCount: damagedPaths.length,
    exportedAt: exportedAt,
    app: r.manifest['app'] as String? ?? '',
  );
}

/// Case-insensitive title/snippet filter; drops groups left with no matches.
List<BackupNotebookGroup> filterGroups(
    List<BackupNotebookGroup> groups, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return groups;
  final out = <BackupNotebookGroup>[];
  for (final g in groups) {
    final matches = g.notes
        .where((n) =>
            n.title.toLowerCase().contains(q) ||
            n.snippet.toLowerCase().contains(q))
        .toList();
    if (matches.isNotEmpty) {
      out.add(BackupNotebookGroup(
          notebookId: g.notebookId, name: g.name, notes: matches));
    }
  }
  return out;
}

/// The header checkbox state for a group given the [selected] set.
TriState groupState(BackupNotebookGroup g, Set<String> selected) {
  var any = false, all = true;
  for (final n in g.notes) {
    if (selected.contains(n.id)) {
      any = true;
    } else {
      all = false;
    }
  }
  if (all && g.notes.isNotEmpty) return TriState.all;
  return any ? TriState.some : TriState.none;
}

Set<String> allNoteIds(List<BackupNotebookGroup> groups) =>
    {for (final g in groups) for (final n in g.notes) n.id};
