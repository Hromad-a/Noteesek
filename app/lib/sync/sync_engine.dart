import 'dart:convert';

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
  static const _labels = 'labels';
  static const _notebooks = 'notebooks';

  bool _running = false;

  /// Runs one full sync cycle. Safe to call concurrently — overlapping calls
  /// are ignored. Returns true if it ran, false if skipped (already running or
  /// not authenticated).
  ///
  /// Each collection's push/pull is an independent step: a non-connectivity
  /// failure in one (e.g. a single malformed record, or a per-collection API
  /// error) is logged and the remaining steps still run, so one bad collection
  /// can't strand the others (notably: a labels-pull failure must not block the
  /// notebooks/notes pull). A connectivity error aborts the cycle and is
  /// rethrown so the caller can show the "server not responding" state.
  ///
  /// [pushOnly] runs just the push half (no pull / byte-download). Used by the
  /// "Keep local only" mirror so the server's data isn't re-acquired locally
  /// before it's deleted.
  Future<bool> syncOnce({bool pushOnly = false}) async {
    if (_running || !_pb.authStore.isValid) return false;
    _running = true;
    try {
      // Push labels and notebooks first so a note's `labels`/`notebook`
      // relations resolve, then parents before children; pull in the same order.
      final steps = <(String, String)>[
        ('push', _labels),
        ('push', _notebooks),
        ('push', _notes),
        ('push', _items),
        ('push', _attachments),
        if (!pushOnly) ...[
          ('pull', _labels),
          ('pull', _notebooks),
          ('pull', _notes),
          ('pull', _items),
          ('pull', _attachments),
          // Retry any attachment whose bytes haven't downloaded yet (independent
          // of the pull cursor).
          ('bytes', _attachments),
        ],
      ];
      for (final (phase, collection) in steps) {
        try {
          await _runStep(phase, collection);
        } catch (e) {
          // Server unreachable: the whole cycle is doomed — abort and let the
          // caller surface the offline state and retry later.
          if (_isConnectivityError(e)) rethrow;
          // Otherwise (data/API error on one collection): skip it, keep going.
          _logStepFailure(phase, collection, e);
        }
      }
      return true;
    } finally {
      _running = false;
    }
  }

  Future<void> _runStep(String phase, String collection) {
    if (phase == 'bytes') return _downloadPendingAttachmentBytes();
    final push = phase == 'push';
    return switch (collection) {
      _labels => push ? _pushLabels() : _pullLabels(),
      _notebooks => push ? _pushNotebooks() : _pullNotebooks(),
      _notes => push ? _pushNotes() : _pullNotes(),
      _items => push ? _pushItems() : _pullItems(),
      _attachments => push ? _pushAttachments() : _pullAttachments(),
      _ => Future<void>.value(),
    };
  }

  void _logStepFailure(String phase, String collection, Object e) {
    // ignore: avoid_print
    print('SyncEngine: $phase $collection failed (skipped): $e');
  }

  /// True for "can't reach the server" errors (offline, server down, timeout) as
  /// opposed to a real API/data error.
  bool _isConnectivityError(Object e) {
    if (e is ClientException && e.statusCode == 0) return true;
    final s = e.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('connection refused') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('connection closed') ||
        s.contains('timed out') ||
        s.contains('timeout');
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

  /// Decodes a note's JSON-array `labels` string into a list of label ids.
  List<String> _decodeIds(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {/* fall through */}
    return const [];
  }

  // ---------------- Push ----------------

  Future<void> _pushLabels() async {
    final dirty =
        await (_db.select(_db.labels)..where((t) => t.dirty.equals(true))).get();
    for (final l in dirty) {
      final body = {
        'owner': l.owner,
        'name': l.name,
        'color': l.color,
        'deleted': l.deleted,
      };
      final saved = await _upsert(_labels, l.id, body);
      if (saved != null) {
        await (_db.update(_db.labels)..where((t) => t.id.equals(l.id))).write(
          LabelsCompanion(
            updated: Value(saved.getStringValue('updated')),
            created: Value(saved.getStringValue('created')),
            dirty: const Value(false),
          ),
        );
      }
    }
  }

  Future<void> _pushNotebooks() async {
    final dirty = await (_db.select(_db.notebooks)
          ..where((t) => t.dirty.equals(true)))
        .get();
    for (final nb in dirty) {
      final body = {
        'owner': nb.owner,
        'name': nb.name,
        'is_default': nb.isDefault,
        'deleted': nb.deleted,
      };
      final saved = await _upsert(_notebooks, nb.id, body);
      if (saved != null) {
        await (_db.update(_db.notebooks)..where((t) => t.id.equals(nb.id)))
            .write(NotebooksCompanion(
          updated: Value(saved.getStringValue('updated')),
          created: Value(saved.getStringValue('created')),
          dirty: const Value(false),
        ));
      }
    }
  }

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
        'color': n.color,
        'labels': _decodeIds(n.labels),
        'notebook': n.notebook,
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

  Future<void> _pullLabels() async {
    await _pull(_labels, (rec) async {
      await _db.into(_db.labels).insertOnConflictUpdate(LabelsCompanion(
            id: Value(rec.id),
            owner: Value(rec.getStringValue('owner')),
            name: Value(rec.getStringValue('name')),
            color: Value(rec.getStringValue('color')),
            deleted: Value(rec.getBoolValue('deleted')),
            created: Value(rec.getStringValue('created')),
            updated: Value(rec.getStringValue('updated')),
            dirty: const Value(false),
          ));
    }, _localLabelUpdated);
  }

  Future<void> _pullNotebooks() async {
    await _pull(_notebooks, (rec) async {
      await _db.into(_db.notebooks).insertOnConflictUpdate(NotebooksCompanion(
            id: Value(rec.id),
            owner: Value(rec.getStringValue('owner')),
            name: Value(rec.getStringValue('name')),
            isDefault: Value(rec.getBoolValue('is_default')),
            deleted: Value(rec.getBoolValue('deleted')),
            created: Value(rec.getStringValue('created')),
            updated: Value(rec.getStringValue('updated')),
            dirty: const Value(false),
          ));
    }, _localNotebookUpdated);
  }

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
            color: Value(rec.getStringValue('color')),
            labels: Value(jsonEncode(rec.getListValue<String>('labels'))),
            notebook: Value(rec.getStringValue('notebook')),
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

  /// Downloads bytes for any attachment that has a server file but no local
  /// bytes yet. This is cursor-independent: a byte download that failed during
  /// [_pullAttachments] would otherwise never retry, because the record's
  /// `updated` is already at/under the pull cursor and won't reappear. Runs
  /// every cycle and is cheap once everything is downloaded (no rows match).
  Future<void> _downloadPendingAttachmentBytes() async {
    final pending = await (_db.select(_db.attachments)
          ..where((t) =>
              t.deleted.equals(false) &
              t.file.equals('').not() &
              t.data.isNull()))
        .get();
    for (final a in pending) {
      try {
        final rec = await _pb.collection(_attachments).getOne(a.id);
        final filename = rec.getStringValue('file');
        if (filename.isEmpty || rec.getBoolValue('deleted')) continue;
        final bytes = await _downloadFile(rec, filename);
        if (bytes != null) {
          await (_db.update(_db.attachments)..where((t) => t.id.equals(a.id)))
              .write(AttachmentsCompanion(data: Value(bytes)));
        }
      } on ClientException catch (e) {
        if (e.statusCode == 404) {
          // Record gone server-side; nothing to download. Leave the row.
          continue;
        }
        rethrow; // connectivity/other — let the cycle handle/abort
      }
    }
  }

  Future<Uint8List?> _downloadFile(RecordModel rec, String filename) async {
    try {
      // Attachment files are protected, so a short-lived file token is required.
      final token = await _pb.files.getToken();
      final url = _pb.files.getUrl(rec, filename, token: token);
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
  ///
  /// Reliability details:
  /// - The filter is `updated >= cursor` (inclusive). A strict `>` would skip
  ///   any record the server stamps with the exact cursor timestamp (same
  ///   millisecond as the newest record from the previous pull), losing it
  ///   forever. Re-applying boundary records is harmless because [apply] is
  ///   idempotent (insert-or-update keyed by id).
  /// - Sort is `updated,id` so pagination is deterministic when timestamps tie
  ///   (the spec's tie-break) — otherwise a record could fall between pages.
  /// - Each record is applied independently; a single record that fails to
  ///   apply doesn't abort the rest. The cursor only advances over the
  ///   *contiguous* successfully-applied prefix, so a failed record (and
  ///   everything after it) is retried next cycle rather than skipped.
  Future<void> _pull(
    String collection,
    Future<void> Function(RecordModel rec) apply,
    Future<({String updated, bool dirty})?> Function(String id) localState,
  ) async {
    final cursor = await _cursor(collection);
    var page = 1;
    // Highest `updated` of the contiguous successfully-applied prefix. Never
    // advanced past a record that failed to apply.
    var safeCursor = cursor;
    var failed = false;

    while (true) {
      final res = await _pb.collection(collection).getList(
            page: page,
            perPage: 200,
            sort: 'updated,id',
            filter: 'updated >= "$cursor"',
          );
      for (final rec in res.items) {
        final serverUpdated = rec.getStringValue('updated');
        try {
          final local = await localState(rec.id);
          // Apply unless we hold a dirty local edit that is newer-or-equal:
          // string compare of ISO timestamps == chronological compare (LWW).
          final keepLocal = local != null &&
              local.dirty &&
              local.updated.compareTo(serverUpdated) >= 0;
          if (!keepLocal) {
            await apply(rec);
          }
          // Records arrive in ascending (updated,id) order, so advancing to the
          // latest success keeps the cursor at the end of the success prefix.
          if (!failed) safeCursor = serverUpdated;
        } catch (e) {
          // One bad record: skip it, stop advancing the cursor (so it's retried
          // next cycle), but keep applying the rest best-effort.
          failed = true;
          // ignore: avoid_print
          print('SyncEngine: pull $collection record ${rec.id} failed: $e');
        }
      }
      if (page >= res.totalPages || res.items.isEmpty) break;
      page++;
    }

    if (safeCursor != cursor) {
      await _setCursor(collection, safeCursor);
    }
  }

  Future<({String updated, bool dirty})?> _localLabelUpdated(String id) async {
    final row = await (_db.select(_db.labels)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (updated: row.updated, dirty: row.dirty);
  }

  Future<({String updated, bool dirty})?> _localNoteUpdated(String id) async {
    final row = await (_db.select(_db.notes)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (updated: row.updated, dirty: row.dirty);
  }

  Future<({String updated, bool dirty})?> _localNotebookUpdated(
      String id) async {
    final row = await (_db.select(_db.notebooks)..where((t) => t.id.equals(id)))
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
