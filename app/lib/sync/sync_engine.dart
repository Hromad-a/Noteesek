import 'package:drift/drift.dart';
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
      // Pull in the same order.
      await _pullNotes();
      await _pullItems();
      return true;
    } finally {
      _running = false;
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
