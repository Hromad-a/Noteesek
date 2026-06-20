import 'dart:typed_data';

import '../../../data/local/ids.dart';
import '../../../data/notes_repository.dart';
import '../../import/import_models.dart';
import '../../import/import_service.dart';
import 'backup_v2.dart';
import 'thumbnailer.dart';

/// "Add as copies" import for a v2 backup: brings the [selectedNoteIds] (null =
/// all) into the current account as **new** notes — fresh ids, current owner,
/// labels/notebooks resolved by name (find-or-create). It reuses
/// [NoteImportService] (the same collision-safe path as the Markdown importer),
/// so it works on mobile and web. Trashed/damaged notes are skipped.
///
/// [targetNotebookName] overrides each note's notebook: null = keep the note's
/// original notebook, '' = no notebook, otherwise that notebook by name.
/// Returns the number of notes added.
Future<int> addNotesFromBackup(
  NotesRepository repo,
  BackupV2Reader r, {
  Set<String>? selectedNoteIds,
  String? targetNotebookName,
}) async {
  final labelNameById = {
    for (final l in r.labels) l['id'] as String: l['name'] as String? ?? ''
  };
  final nbNameById = {
    for (final nb in r.notebooks) nb['id'] as String: nb['name'] as String? ?? ''
  };

  String? resolveNotebook(Object? originalId) {
    if (targetNotebookName != null) {
      return targetNotebookName.isEmpty ? null : targetNotebookName;
    }
    final name = nbNameById[originalId] ?? '';
    return name.isEmpty ? null : name;
  }

  final parsed = <ParsedNote>[];
  for (final idx in r.notes) {
    final id = idx['id'] as String;
    if (selectedNoteIds != null && !selectedNoteIds.contains(id)) continue;
    final rec = r.noteRecord(id);
    if (rec == null) continue; // damaged → skip
    if (rec['deleted'] == true) continue; // don't copy trashed

    final labelNames = <String>[
      for (final lid in ((rec['labelIds'] as List?) ?? const []))
        if ((labelNameById[lid] ?? '').isNotEmpty) labelNameById[lid]!,
    ];
    final items = <ImportedItem>[
      for (final i in ((rec['items'] as List?) ?? const []))
        if ((i as Map)['deleted'] != true)
          ImportedItem(
              i['text'] as String? ?? '', i['checked'] as bool? ?? false),
    ];
    final images = <Uint8List>[];
    for (final a in ((rec['attachments'] as List?) ?? const [])) {
      final m = (a as Map).cast<String, dynamic>();
      if (m['deleted'] == true) continue;
      final sha = m['sha256'] as String?;
      final bytes =
          sha == null ? null : r.attachmentBytes(sha, m['ext'] as String? ?? 'jpg');
      if (bytes != null) images.add(bytes);
    }

    parsed.add(ParsedNote(
      type: rec['type'] as String? ?? 'text',
      title: rec['title'] as String? ?? '',
      body: rec['body'] as String? ?? '',
      color: rec['color'] as String? ?? '',
      pinned: rec['pinned'] as bool? ?? false,
      archived: rec['archived'] as bool? ?? false,
      labelNames: labelNames,
      notebookName: resolveNotebook(rec['notebookId']),
      items: items,
      images: images,
    ));
  }

  return (await NoteImportService(repo).import(parsed)).imported;
}

/// Packs [notes] (from a Markdown/Keep import, a snapshot, etc.) into an
/// in-memory v2 zip so they flow through the shared preview/restore screen.
/// Labels and the notebook are name-based here; ids are synthetic (only
/// internally consistent) — the Add import resolves names to real ids.
Future<Uint8List> parsedNotesToBackupBytes(List<ParsedNote> notes) async {
  final labelId = <String, String>{};
  final notebookId = <String, String>{};
  for (final n in notes) {
    for (final name in n.labelNames) {
      labelId.putIfAbsent(name, newPbId);
    }
    final nb = n.notebookName;
    if (nb != null && nb.trim().isNotEmpty) notebookId.putIfAbsent(nb, newPbId);
  }

  final input = BackupInput(
    labels: [
      for (final e in labelId.entries) BackupLabelInput(id: e.value, name: e.key)
    ],
    notebooks: [
      for (final e in notebookId.entries)
        BackupNotebookInput(id: e.value, name: e.key)
    ],
    notes: [
      for (final n in notes)
        BackupNoteInput(
          id: newPbId(),
          type: n.type,
          title: n.title,
          body: n.body,
          color: n.color,
          pinned: n.pinned,
          archived: n.archived,
          labelIds: [for (final name in n.labelNames) labelId[name]!],
          notebookId: (n.notebookName != null && n.notebookName!.trim().isNotEmpty)
              ? notebookId[n.notebookName]!
              : '',
          items: [
            for (final i in n.items)
              BackupItemInput(id: newPbId(), text: i.content, checked: i.checked)
          ],
          attachments: [
            for (final img in n.images)
              BackupAttachmentInput(id: newPbId(), bytes: img)
          ],
        ),
    ],
  );
  return writeBackupV2(input, thumbnailer: makeThumbnail);
}
