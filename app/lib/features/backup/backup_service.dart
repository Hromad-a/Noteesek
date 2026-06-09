import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/local/database.dart';

/// Full local-database backup/restore (mobile). Serializes every row of every
/// table — including attachment bytes (base64) and the original ids/timestamps —
/// to one JSON file, and restores it losslessly (upsert by id). Restored rows
/// are marked `dirty` so a later sync re-pushes them.
///
/// This is distinct from the Markdown import/export: it round-trips the exact
/// data (ids, sync metadata) rather than human-readable notes.
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  /// Bumped if the JSON layout changes incompatibly.
  static const int formatVersion = 1;

  Future<Uint8List> export() async {
    final data = <String, dynamic>{
      'format': formatVersion,
      'schema': _db.schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'notes':
          (await _db.select(_db.notes).get()).map(_noteJson).toList(),
      'checklistItems': (await _db.select(_db.checklistItems).get())
          .map(_itemJson)
          .toList(),
      'attachments': (await _db.select(_db.attachments).get())
          .map(_attachmentJson)
          .toList(),
      'labels':
          (await _db.select(_db.labels).get()).map(_labelJson).toList(),
      'notebooks':
          (await _db.select(_db.notebooks).get()).map(_notebookJson).toList(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(data)));
  }

  /// Restores [bytes]. Upserts every row by id (preserving created/updated) and
  /// marks them dirty so the next sync re-pushes. Returns the number of notes
  /// restored. Throws [FormatException] on a malformed/incompatible file.
  Future<int> import(Uint8List bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['format'] != formatVersion) {
      throw const FormatException('Not a Noteesek backup file');
    }
    final json = decoded.cast<String, dynamic>();
    List<Map<String, dynamic>> rows(String key) =>
        ((json[key] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();

    final notes = rows('notes');
    await _db.transaction(() async {
      for (final m in rows('notebooks')) {
        await _db.into(_db.notebooks).insertOnConflictUpdate(_notebookRow(m));
      }
      for (final m in rows('labels')) {
        await _db.into(_db.labels).insertOnConflictUpdate(_labelRow(m));
      }
      for (final m in notes) {
        await _db.into(_db.notes).insertOnConflictUpdate(_noteRow(m));
      }
      for (final m in rows('checklistItems')) {
        await _db
            .into(_db.checklistItems)
            .insertOnConflictUpdate(_itemRow(m));
      }
      for (final m in rows('attachments')) {
        await _db
            .into(_db.attachments)
            .insertOnConflictUpdate(_attachmentRow(m));
      }
    });
    return notes.length;
  }

  // ---- row → json ----

  Map<String, dynamic> _noteJson(NoteRow n) => {
        'id': n.id,
        'owner': n.owner,
        'type': n.type,
        'title': n.title,
        'body': n.body,
        'pinned': n.pinned,
        'archived': n.archived,
        'color': n.color,
        'labels': n.labels,
        'notebook': n.notebook,
        'deleted': n.deleted,
        'created': n.created,
        'updated': n.updated,
        'position': n.position,
      };

  Map<String, dynamic> _itemJson(ChecklistItemRow i) => {
        'id': i.id,
        'note': i.note,
        'content': i.content,
        'checked': i.checked,
        'position': i.position,
        'deleted': i.deleted,
        'created': i.created,
        'updated': i.updated,
      };

  Map<String, dynamic> _attachmentJson(AttachmentRow a) => {
        'id': a.id,
        'note': a.note,
        'file': a.file,
        'data': a.data == null ? null : base64Encode(a.data!),
        'deleted': a.deleted,
        'created': a.created,
        'updated': a.updated,
      };

  Map<String, dynamic> _labelJson(LabelRow l) => {
        'id': l.id,
        'owner': l.owner,
        'name': l.name,
        'color': l.color,
        'deleted': l.deleted,
        'created': l.created,
        'updated': l.updated,
      };

  Map<String, dynamic> _notebookJson(NotebookRow n) => {
        'id': n.id,
        'owner': n.owner,
        'name': n.name,
        'deleted': n.deleted,
        'created': n.created,
        'updated': n.updated,
      };

  // ---- json → companion (dirty so it re-syncs) ----

  NotesCompanion _noteRow(Map<String, dynamic> m) => NotesCompanion.insert(
        id: m['id'] as String,
        owner: m['owner'] as String,
        type: Value(m['type'] as String? ?? 'text'),
        title: Value(m['title'] as String? ?? ''),
        body: Value(m['body'] as String? ?? ''),
        pinned: Value(m['pinned'] as bool? ?? false),
        archived: Value(m['archived'] as bool? ?? false),
        color: Value(m['color'] as String? ?? ''),
        labels: Value(m['labels'] as String? ?? '[]'),
        notebook: Value(m['notebook'] as String? ?? ''),
        deleted: Value(m['deleted'] as bool? ?? false),
        created: Value(m['created'] as String?),
        updated: Value(m['updated'] as String? ?? ''),
        position: Value(m['position'] as int? ?? 0),
        dirty: const Value(true),
      );

  ChecklistItemsCompanion _itemRow(Map<String, dynamic> m) =>
      ChecklistItemsCompanion.insert(
        id: m['id'] as String,
        note: m['note'] as String,
        content: Value(m['content'] as String? ?? ''),
        checked: Value(m['checked'] as bool? ?? false),
        position: Value(m['position'] as int? ?? 0),
        deleted: Value(m['deleted'] as bool? ?? false),
        created: Value(m['created'] as String?),
        updated: Value(m['updated'] as String? ?? ''),
        dirty: const Value(true),
      );

  AttachmentsCompanion _attachmentRow(Map<String, dynamic> m) =>
      AttachmentsCompanion.insert(
        id: m['id'] as String,
        note: m['note'] as String,
        file: Value(m['file'] as String? ?? ''),
        data: Value(
            m['data'] == null ? null : base64Decode(m['data'] as String)),
        deleted: Value(m['deleted'] as bool? ?? false),
        created: Value(m['created'] as String?),
        updated: Value(m['updated'] as String? ?? ''),
        dirty: const Value(true),
      );

  LabelsCompanion _labelRow(Map<String, dynamic> m) => LabelsCompanion.insert(
        id: m['id'] as String,
        owner: m['owner'] as String,
        name: Value(m['name'] as String? ?? ''),
        color: Value(m['color'] as String? ?? ''),
        deleted: Value(m['deleted'] as bool? ?? false),
        created: Value(m['created'] as String?),
        updated: Value(m['updated'] as String? ?? ''),
        dirty: const Value(true),
      );

  NotebooksCompanion _notebookRow(Map<String, dynamic> m) =>
      NotebooksCompanion.insert(
        id: m['id'] as String,
        owner: m['owner'] as String,
        name: Value(m['name'] as String? ?? ''),
        deleted: Value(m['deleted'] as bool? ?? false),
        created: Value(m['created'] as String?),
        updated: Value(m['updated'] as String? ?? ''),
        dirty: const Value(true),
      );
}
