import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/local/database.dart';
import '../../data/local/ids.dart';
import 'v2/backup_v2.dart';
import 'v2/thumbnailer.dart';

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

  // ---- v2 (zip) format ----

  static List<String> _ids(String rawJson) {
    try {
      final d = jsonDecode(rawJson);
      if (d is List) return d.map((e) => e.toString()).toList();
    } catch (_) {/* fall through */}
    return const [];
  }

  /// Gathers the whole local DB into the platform-agnostic v2 input.
  Future<BackupInput> _gatherV2() async {
    final notes = await _db.select(_db.notes).get();
    final itemsByNote = <String, List<ChecklistItemRow>>{};
    for (final i in await _db.select(_db.checklistItems).get()) {
      (itemsByNote[i.note] ??= []).add(i);
    }
    final attsByNote = <String, List<AttachmentRow>>{};
    for (final a in await _db.select(_db.attachments).get()) {
      (attsByNote[a.note] ??= []).add(a);
    }
    return BackupInput(
      labels: [
        for (final l in await _db.select(_db.labels).get())
          BackupLabelInput(
              id: l.id,
              name: l.name,
              color: l.color,
              deleted: l.deleted,
              created: l.created,
              updated: l.updated),
      ],
      backgrounds: [
        for (final b in await _db.select(_db.backgrounds).get())
          BackupBackgroundInput(
              id: b.id,
              name: b.name,
              bytes: b.data,
              opacity: b.opacity,
              overlayColor: b.overlayColor,
              overlayOpacity: b.overlayOpacity,
              fit: b.fit,
              repeat: b.repeat,
              scale: b.scale,
              deleted: b.deleted,
              created: b.created,
              updated: b.updated),
      ],
      notebooks: [
        for (final nb in await _db.select(_db.notebooks).get())
          BackupNotebookInput(
              id: nb.id,
              name: nb.name,
              deleted: nb.deleted,
              created: nb.created,
              updated: nb.updated),
      ],
      notes: [
        for (final n in notes)
          BackupNoteInput(
            id: n.id,
            type: n.type,
            title: n.title,
            body: n.body,
            color: n.color,
            pinned: n.pinned,
            archived: n.archived,
            deleted: n.deleted,
            position: n.position,
            created: n.created,
            updated: n.updated,
            labelIds: _ids(n.labels),
            notebookId: n.notebook,
            background: n.background,
            items: [
              for (final i in (itemsByNote[n.id] ?? const []))
                BackupItemInput(
                    id: i.id,
                    text: i.content,
                    checked: i.checked,
                    position: i.position,
                    deleted: i.deleted,
                    created: i.created,
                    updated: i.updated),
            ],
            attachments: [
              for (final a in (attsByNote[n.id] ?? const []))
                BackupAttachmentInput(
                    id: a.id,
                    bytes: a.data,
                    deleted: a.deleted,
                    created: a.created,
                    updated: a.updated),
            ],
          ),
      ],
    );
  }

  /// Exports the whole local DB as a v2 backup zip.
  Future<Uint8List> exportV2() async => writeBackupV2(await _gatherV2(), thumbnailer: makeThumbnail);

  /// Restores a v2 zip in place (upsert **by id**), stamping [owner]. With
  /// [selectedNoteIds] only those notes are restored (the rest of the account is
  /// left alone) — no duplicates, since matching is by id. With [mirror] the
  /// account is made to match the backup exactly: notes absent from it are moved
  /// to Trash. Damaged entries are skipped. Returns the number of notes restored.
  Future<int> importV2(Uint8List bytes, String owner,
      {Set<String>? selectedNoteIds, bool mirror = false}) async {
    final r = BackupV2Reader.read(bytes);
    var count = 0;
    final backupNotebookIds = <String>{};
    final backupLabelIds = <String>{};
    await _db.transaction(() async {
      for (final nb in r.notebooks) {
        backupNotebookIds.add(nb['id'] as String);
        await _db.into(_db.notebooks).insertOnConflictUpdate(
            NotebooksCompanion.insert(
                id: nb['id'] as String,
                owner: owner,
                name: Value(nb['name'] as String? ?? ''),
                deleted: Value(nb['deleted'] as bool? ?? false),
                created: Value(nb['created'] as String?),
                updated: Value(nb['updated'] as String? ?? ''),
                dirty: const Value(true)));
      }
      for (final l in r.labels) {
        backupLabelIds.add(l['id'] as String);
        await _db.into(_db.labels).insertOnConflictUpdate(LabelsCompanion.insert(
            id: l['id'] as String,
            owner: owner,
            name: Value(l['name'] as String? ?? ''),
            color: Value(l['color'] as String? ?? ''),
            deleted: Value(l['deleted'] as bool? ?? false),
            created: Value(l['created'] as String?),
            updated: Value(l['updated'] as String? ?? ''),
            dirty: const Value(true)));
      }
      final backupBgIds = <String>{};
      for (final b in r.backgrounds) {
        backupBgIds.add(b['id'] as String);
        final sha = b['sha256'] as String?;
        final ext = b['ext'] as String? ?? 'jpg';
        final deleted = b['deleted'] as bool? ?? false;
        final data = sha == null ? null : r.backgroundBytes(sha, ext);
        if (data == null && !deleted) continue; // missing/damaged bytes
        await _db.into(_db.backgrounds).insertOnConflictUpdate(
            BackgroundsCompanion.insert(
                id: b['id'] as String,
                owner: owner,
                name: Value(b['name'] as String? ?? ''),
                file: const Value(''),
                data: Value(data),
                opacity: Value((b['opacity'] as num?)?.toDouble() ?? 1),
                overlayColor: Value(b['overlayColor'] as String? ?? ''),
                overlayOpacity:
                    Value((b['overlayOpacity'] as num?)?.toDouble() ?? 0),
                fit: Value(b['fit'] as String? ?? 'cover'),
                repeat: Value(b['repeat'] as String? ?? 'none'),
                scale: Value((b['scale'] as num?)?.toDouble() ?? 1),
                deleted: Value(deleted),
                created: Value(b['created'] as String?),
                updated: Value(b['updated'] as String? ?? ''),
                dirty: const Value(true)));
      }
      final backupNoteIds = <String>{};
      for (final idx in r.notes) {
        final id = idx['id'] as String;
        backupNoteIds.add(id);
        if (selectedNoteIds != null && !selectedNoteIds.contains(id)) continue;
        final rec = r.noteRecord(id);
        if (rec == null) continue; // damaged → skip, keep the rest
        await _db.into(_db.notes).insertOnConflictUpdate(NotesCompanion.insert(
            id: rec['id'] as String,
            owner: owner,
            type: Value(rec['type'] as String? ?? 'text'),
            title: Value(rec['title'] as String? ?? ''),
            body: Value(rec['body'] as String? ?? ''),
            pinned: Value(rec['pinned'] as bool? ?? false),
            archived: Value(rec['archived'] as bool? ?? false),
            color: Value(rec['color'] as String? ?? ''),
            background: Value(rec['background'] as String? ?? ''),
            labels: Value(jsonEncode((rec['labelIds'] as List?) ?? const [])),
            notebook: Value(rec['notebookId'] as String? ?? ''),
            deleted: Value(rec['deleted'] as bool? ?? false),
            position: Value(rec['position'] as int? ?? 0),
            created: Value(rec['created'] as String?),
            updated: Value(rec['updated'] as String? ?? ''),
            dirty: const Value(true)));
        for (final i in ((rec['items'] as List?) ?? const [])) {
          final m = (i as Map).cast<String, dynamic>();
          await _db.into(_db.checklistItems).insertOnConflictUpdate(
              ChecklistItemsCompanion.insert(
                  id: m['id'] as String,
                  note: rec['id'] as String,
                  content: Value(m['text'] as String? ?? ''),
                  checked: Value(m['checked'] as bool? ?? false),
                  position: Value(m['position'] as int? ?? 0),
                  deleted: Value(m['deleted'] as bool? ?? false),
                  created: Value(m['created'] as String?),
                  updated: Value(m['updated'] as String? ?? ''),
                  dirty: const Value(true)));
        }
        for (final a in ((rec['attachments'] as List?) ?? const [])) {
          final m = (a as Map).cast<String, dynamic>();
          final sha = m['sha256'] as String?;
          final ext = m['ext'] as String? ?? 'jpg';
          final deleted = m['deleted'] as bool? ?? false;
          final data = sha == null ? null : r.attachmentBytes(sha, ext);
          if (data == null && !deleted) continue; // missing/damaged bytes
          await _db.into(_db.attachments).insertOnConflictUpdate(
              AttachmentsCompanion.insert(
                  id: m['id'] as String,
                  note: rec['id'] as String,
                  file: const Value(''),
                  data: Value(data),
                  deleted: Value(deleted),
                  created: Value(m['created'] as String?),
                  updated: Value(m['updated'] as String? ?? ''),
                  dirty: const Value(true)));
        }
        count++;
      }
      if (mirror) {
        // Make the account match the backup exactly: Trash notes, notebooks and
        // labels that aren't in it.
        for (final n in await _db.select(_db.notes).get()) {
          if (!backupNoteIds.contains(n.id) && !n.deleted) {
            await (_db.update(_db.notes)..where((t) => t.id.equals(n.id)))
                .write(NotesCompanion(
                    deleted: const Value(true),
                    updated: Value(pbNow()),
                    dirty: const Value(true)));
          }
        }
        for (final nb in await _db.select(_db.notebooks).get()) {
          if (!backupNotebookIds.contains(nb.id) && !nb.deleted) {
            await (_db.update(_db.notebooks)..where((t) => t.id.equals(nb.id)))
                .write(NotebooksCompanion(
                    deleted: const Value(true),
                    updated: Value(pbNow()),
                    dirty: const Value(true)));
          }
        }
        for (final l in await _db.select(_db.labels).get()) {
          if (!backupLabelIds.contains(l.id) && !l.deleted) {
            await (_db.update(_db.labels)..where((t) => t.id.equals(l.id)))
                .write(LabelsCompanion(
                    deleted: const Value(true),
                    updated: Value(pbNow()),
                    dirty: const Value(true)));
          }
        }
        for (final b in await _db.select(_db.backgrounds).get()) {
          if (!backupBgIds.contains(b.id) && !b.deleted) {
            await (_db.update(_db.backgrounds)..where((t) => t.id.equals(b.id)))
                .write(BackgroundsCompanion(
                    deleted: const Value(true),
                    updated: Value(pbNow()),
                    dirty: const Value(true)));
          }
        }
      }
    });
    return count;
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
        background: Value(m['background'] as String? ?? ''),
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
