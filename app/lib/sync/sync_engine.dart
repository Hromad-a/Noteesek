import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../data/local/database.dart';

/// Implements the last-write-wins sync described in docs/sync-protocol.md.
///
/// Per cycle: push all dirty rows (parents before children), then pull records
/// changed since each collection's cursor and merge them with per-record LWW.
/// The server is the source of truth for conflict resolution; whoever syncs
/// last wins.
class SyncEngine {
  SyncEngine(this._db, this._pb);

  final AppDatabase _db;
  final PocketBase _pb;

  static const _notes = 'notes';
  static const _items = 'checklist_items';
  static const _attachments = 'attachments';

  bool _running = false;

  /// Runs one full sync cycle. Safe to call concurrently — overlapping calls
  /// are ignored. Returns true if it ran, false if skipped (already running or
  /// not authenticated).
  Future<bool> syncOnce() async {
    if (_running || !_pb.authStore.isValid) return false;
    _running = true;
    try {
      // Push parents before children so a child's `note` relation resolves.
      await _pushNotes();
      await _pushItems();
      await _pushAttachments();
      // Pull in the same order.
      await _pullNotes();
      await _pullItems();
      await _pullAttachments();
      return true;
    } finally {
      _running = false;
    }
  }

  /// Permanently delete a note on the server (children cascade-delete via the
  /// relation). Best-effort: no-op when offline/not connected; 404 is treated
  /// as already gone. Used by "delete forever" / "empty trash".
  Future<void> deleteNoteRemote(String noteId) async {
    if (!_pb.authStore.isValid) return;
    try {
      await _pb.collection(_notes).delete(noteId);
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
  }

  // ---------------- Push ----------------

  Future<void> _pushNotes() async {
    final dirty =
        await (_db.select(_db.notes)..where((t) => t.dirty.equals(true))).get();
    for (final n in dirty) {
      final body = {
        'owner': n.owner,
        'type': n.type,
        'title': n.title,
        'body': n.body,
        'pinned': n.pinned,
        'archived': n.archived,
        'deleted': n.deleted,
      };
      final saved = await _upsert(_notes, n.id, body);
      if (saved != null) {
        await (_db.update(_db.notes)..where((t) => t.id.equals(n.id))).write(
          NotesCompanion(
            updated: Value(saved.getStringValue('updated')),
            created: Value(saved.getStringValue('created')),
            dirty: const Value(false),
          ),
        );
      }
    }
  }

  Future<void> _pushItems() async {
    final dirty = await (_db.select(_db.checklistItems)
          ..where((t) => t.dirty.equals(true)))
        .get();
    for (final it in dirty) {
      final body = {
        'note': it.note,
        'text': it.content, // local `content` maps to PB `text`
        'checked': it.checked,
        'position': it.position,
        'deleted': it.deleted,
      };
      final saved = await _upsert(_items, it.id, body);
      if (saved != null) {
        await (_db.update(_db.checklistItems)
              ..where((t) => t.id.equals(it.id)))
            .write(ChecklistItemsCompanion(
          updated: Value(saved.getStringValue('updated')),
          created: Value(saved.getStringValue('created')),
          dirty: const Value(false),
        ));
      }
    }
  }

  Future<void> _pushAttachments() async {
    final dirty = await (_db.select(_db.attachments)
          ..where((t) => t.dirty.equals(true)))
        .get();
    for (final a in dirty) {
      try {
        RecordModel saved;
        if (a.file.isEmpty && a.data != null && !a.deleted) {
          // Not yet uploaded: create with the image bytes (multipart).
          saved = await _pb.collection(_attachments).create(
            body: {'id': a.id, 'note': a.note, 'deleted': false},
            files: [
              http.MultipartFile.fromBytes('file', a.data!,
                  filename: 'img_${a.id}.jpg'),
            ],
          );
        } else {
          // Metadata-only change (e.g. soft delete) on an existing record.
          saved = await _pb
              .collection(_attachments)
              .update(a.id, body: {'deleted': a.deleted});
        }
        await (_db.update(_db.attachments)..where((t) => t.id.equals(a.id)))
            .write(AttachmentsCompanion(
          file: Value(saved.getStringValue('file')),
          created: Value(saved.getStringValue('created')),
          updated: Value(saved.getStringValue('updated')),
          dirty: const Value(false),
        ));
      } on ClientException catch (e) {
        // A delete of something never uploaded → nothing to do server-side.
        if (e.statusCode == 404 && a.deleted) {
          await (_db.update(_db.attachments)..where((t) => t.id.equals(a.id)))
              .write(const AttachmentsCompanion(dirty: Value(false)));
        }
        // else: transient error, leave dirty and retry next cycle.
      }
    }
  }

  /// Update the record by id; if it doesn't exist yet on the server, create it
  /// with the same (client-generated) id. Returns the saved record, or null if
  /// the push should be retried later (e.g. transient network error).
  Future<RecordModel?> _upsert(
      String collection, String id, Map<String, dynamic> body) async {
    try {
      return await _pb.collection(collection).update(id, body: body);
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        try {
          return await _pb
              .collection(collection)
              .create(body: {'id': id, ...body});
        } on ClientException {
          return null;
        }
      }
      // Network / server error — leave dirty, retry next cycle.
      return null;
    }
  }

  // ---------------- Pull ----------------

  Future<void> _pullNotes() async {
    await _pull(_notes, (rec) async {
      await _db.into(_db.notes).insertOnConflictUpdate(NotesCompanion(
            id: Value(rec.id),
            owner: Value(rec.getStringValue('owner')),
            type: Value(rec.getStringValue('type')),
            title: Value(rec.getStringValue('title')),
            body: Value(rec.getStringValue('body')),
            pinned: Value(rec.getBoolValue('pinned')),
            archived: Value(rec.getBoolValue('archived')),
            deleted: Value(rec.getBoolValue('deleted')),
            created: Value(rec.getStringValue('created')),
            updated: Value(rec.getStringValue('updated')),
            dirty: const Value(false),
          ));
    }, _localNoteUpdated);
  }

  Future<void> _pullItems() async {
    await _pull(_items, (rec) async {
      await _db
          .into(_db.checklistItems)
          .insertOnConflictUpdate(ChecklistItemsCompanion(
            id: Value(rec.id),
            note: Value(rec.getStringValue('note')),
            content: Value(rec.getStringValue('text')),
            checked: Value(rec.getBoolValue('checked')),
            position: Value(rec.getIntValue('position')),
            deleted: Value(rec.getBoolValue('deleted')),
            created: Value(rec.getStringValue('created')),
            updated: Value(rec.getStringValue('updated')),
            dirty: const Value(false),
          ));
    }, _localItemUpdated);
  }

  Future<void> _pullAttachments() async {
    await _pull(_attachments, (rec) async {
      // Upsert metadata; omit `data` so locally-held bytes are preserved.
      await _db
          .into(_db.attachments)
          .insertOnConflictUpdate(AttachmentsCompanion(
            id: Value(rec.id),
            note: Value(rec.getStringValue('note')),
            file: Value(rec.getStringValue('file')),
            deleted: Value(rec.getBoolValue('deleted')),
            created: Value(rec.getStringValue('created')),
            updated: Value(rec.getStringValue('updated')),
            dirty: const Value(false),
          ));

      // If we don't have the bytes yet (came from another device), download.
      final filename = rec.getStringValue('file');
      if (filename.isEmpty || rec.getBoolValue('deleted')) return;
      final existing = await (_db.select(_db.attachments)
            ..where((t) => t.id.equals(rec.id)))
          .getSingleOrNull();
      if (existing?.data != null) return;

      final bytes = await _downloadFile(rec, filename);
      if (bytes != null) {
        await (_db.update(_db.attachments)..where((t) => t.id.equals(rec.id)))
            .write(AttachmentsCompanion(data: Value(bytes)));
      }
    }, _localAttachmentUpdated);
  }

  Future<Uint8List?> _downloadFile(RecordModel rec, String filename) async {
    try {
      final url = _pb.files.getUrl(rec, filename);
      final resp = await http.get(url);
      return resp.statusCode == 200 ? resp.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<({String updated, bool dirty})?> _localAttachmentUpdated(
      String id) async {
    final row = await (_db.select(_db.attachments)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (updated: row.updated, dirty: row.dirty);
  }

  /// Generic pull loop: fetch records changed since the cursor, apply each with
  /// last-write-wins, then advance the cursor.
  Future<void> _pull(
    String collection,
    Future<void> Function(RecordModel rec) apply,
    Future<({String updated, bool dirty})?> Function(String id) localState,
  ) async {
    final cursor = await _cursor(collection);
    var page = 1;
    var maxUpdated = cursor;

    while (true) {
      final res = await _pb.collection(collection).getList(
            page: page,
            perPage: 200,
            sort: 'updated',
            filter: 'updated > "$cursor"',
          );
      for (final rec in res.items) {
        final serverUpdated = rec.getStringValue('updated');
        if (serverUpdated.compareTo(maxUpdated) > 0) {
          maxUpdated = serverUpdated;
        }
        final local = await localState(rec.id);
        // Apply unless we hold a dirty local edit that is newer-or-equal:
        // string compare of ISO timestamps == chronological compare (LWW).
        final keepLocal = local != null &&
            local.dirty &&
            local.updated.compareTo(serverUpdated) >= 0;
        if (!keepLocal) {
          await apply(rec);
        }
      }
      if (page >= res.totalPages || res.items.isEmpty) break;
      page++;
    }

    if (maxUpdated != cursor) {
      await _setCursor(collection, maxUpdated);
    }
  }

  Future<({String updated, bool dirty})?> _localNoteUpdated(String id) async {
    final row = await (_db.select(_db.notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (updated: row.updated, dirty: row.dirty);
  }

  Future<({String updated, bool dirty})?> _localItemUpdated(String id) async {
    final row =
        await (_db.select(_db.checklistItems)..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : (updated: row.updated, dirty: row.dirty);
  }

  // ---------------- Cursor ----------------

  Future<String> _cursor(String collection) async {
    final row = await (_db.select(_db.syncCursors)
          ..where((t) => t.collection.equals(collection)))
        .getSingleOrNull();
    return row?.lastSynced ?? '';
  }

  Future<void> _setCursor(String collection, String value) async {
    await _db.into(_db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion(
            collection: Value(collection),
            lastSynced: Value(value),
          ),
        );
  }
}
