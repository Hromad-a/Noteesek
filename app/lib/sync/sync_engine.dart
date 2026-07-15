import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../config/app_config.dart';
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
  static const _backgrounds = 'backgrounds';

  /// The auth collection whose token authenticates every request.
  static const _users = 'users';

  /// How stale the token may get before a sync cycle renews it. PocketBase
  /// tokens have a fixed TTL (7 days by default) and are otherwise never
  /// refreshed, so without this the user is silently logged out one token
  /// lifetime after signing in. Refreshing well inside the TTL keeps a session
  /// alive indefinitely as long as the app is opened occasionally.
  static const _authRefreshInterval = Duration(hours: 6);

  bool _running = false;

  /// When the token was last successfully renewed (in-memory; null until the
  /// first refresh this run, so a fresh launch always renews once).
  DateTime? _lastAuthRefresh;

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
      // Keep the session alive before doing any work: renew the token if it's
      // getting old so a long-lived session doesn't silently expire out from
      // under the user. If the token was genuinely rejected it's cleared here,
      // so bail rather than fire a cycle's worth of doomed 401s.
      await _maybeRefreshAuth();
      if (!_pb.authStore.isValid) return false;
      // Push labels and notebooks first so a note's `labels`/`notebook`
      // relations resolve, then parents before children; pull in the same order.
      final steps = <(String, String)>[
        ('push', _labels),
        ('push', _notebooks),
        ('push', _backgrounds),
        ('push', _notes),
        ('push', _items),
        ('push', _attachments),
        if (!pushOnly) ...[
          ('pull', _labels),
          ('pull', _notebooks),
          ('pull', _backgrounds),
          ('pull', _notes),
          ('pull', _items),
          ('pull', _attachments),
          // Retry any attachment / background whose bytes haven't downloaded yet
          // (independent of the pull cursor).
          ('bytes', _attachments),
          ('bytes', _backgrounds),
          // Fetch foreign backgrounds that shared notes reference (our own
          // library pull is owner-scoped, so these arrive only by id).
          ('refbg', _backgrounds),
          // Fully fetch shared-with-me notebooks' content (cursor-independent):
          // a note granted access later (e.g. a notebook (re)shared, or restored
          // notes) can have an `updated` older than our pull cursor, so the
          // incremental pull above would miss it.
          ('sharedpull', _notebooks),
          // Drop shared notebooks (+ their notes) that were unshared from me,
          // and individual notes I've lost access to (e.g. a member claimed one
          // out of a shared notebook, taking its ownership).
          ('reconcile', _notebooks),
          ('reconcile', _notes),
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

  /// Renews the auth token when it's older than [_authRefreshInterval], so a
  /// long-running or frequently-reopened session never ages past the server's
  /// token TTL. Throttled so it doesn't fire on every 30s cycle.
  ///
  /// Fail-soft by design: a connectivity error leaves the current (still
  /// locally-valid) token untouched to retry next cycle, so a flaky network
  /// can't log the user out. A genuine 401 means the token is truly dead — the
  /// auth-guard http client clears the session for us, and [syncOnce] then bails.
  Future<void> _maybeRefreshAuth() async {
    if (!_pb.authStore.isValid) return;
    final now = DateTime.now();
    final last = _lastAuthRefresh;
    if (last != null && now.difference(last) < _authRefreshInterval) return;
    try {
      await _pb.collection(_users).authRefresh();
      _lastAuthRefresh = now;
    } catch (e) {
      // 401 → token rejected and already cleared by the auth guard; nothing to
      // do. Network/other errors are transient: keep the token and retry later.
      if (_isConnectivityError(e)) return;
      // ignore: avoid_print
      print('SyncEngine: auth refresh failed: $e');
    }
  }

  Future<void> _runStep(String phase, String collection) {
    if (phase == 'bytes') {
      return collection == _backgrounds
          ? _downloadPendingBackgroundBytes()
          : _downloadPendingAttachmentBytes();
    }
    if (phase == 'refbg') return _fetchReferencedBackgrounds();
    if (phase == 'sharedpull') return _pullSharedNotebookContent();
    if (phase == 'reconcile') {
      return collection == _notes
          ? _reconcileSharedNotes()
          : _reconcileSharedNotebooks();
    }
    final push = phase == 'push';
    return switch (collection) {
      _labels => push ? _pushLabels() : _pullLabels(),
      _notebooks => push ? _pushNotebooks() : _pullNotebooks(),
      _backgrounds => push ? _pushBackgrounds() : _pullBackgrounds(),
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

  /// Make the local copy of one note (and its items/attachments) match the
  /// server exactly, **discarding any unsynced local edits** to it. Used for
  /// shared notes on reconnect ("server is the authority"): brief edits made
  /// during an offline blip are dropped rather than pushed, so the device that
  /// went offline can't diverge from everyone else.
  Future<void> refetchNote(String noteId) async {
    if (!_pb.authStore.isValid) return;
    try {
      final n = await _pb.collection(_notes).getOne(noteId);
      await _applyRecord(_notes, n); // overwrites local (dirty cleared)

      final items = await _pb
          .collection(_items)
          .getFullList(batch: 500, filter: 'note = "$noteId"');
      final itemIds = {for (final r in items) r.id};
      for (final r in items) {
        await _applyRecord(_items, r);
      }
      // Drop local-only items (created offline, never on the server).
      for (final li in await (_db.select(_db.checklistItems)
            ..where((t) => t.note.equals(noteId)))
          .get()) {
        if (!itemIds.contains(li.id)) {
          await (_db.delete(_db.checklistItems)..where((t) => t.id.equals(li.id)))
              .go();
        }
      }

      final atts = await _pb
          .collection(_attachments)
          .getFullList(batch: 500, filter: 'note = "$noteId"');
      final attIds = {for (final r in atts) r.id};
      for (final r in atts) {
        await _applyRecord(_attachments, r);
      }
      for (final la in await (_db.select(_db.attachments)
            ..where((t) => t.note.equals(noteId)))
          .get()) {
        if (!attIds.contains(la.id)) {
          await (_db.delete(_db.attachments)..where((t) => t.id.equals(la.id)))
              .go();
        }
      }
    } catch (_) {
      // Offline/transient — leave local as-is; the next reconnect retries.
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
        'sharedWith': _decodeIds(nb.sharedWith),
        'hidden_from_all': nb.hiddenFromAll,
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

  Future<void> _pushBackgrounds() async {
    final dirty = await (_db.select(_db.backgrounds)
          ..where((t) => t.dirty.equals(true)))
        .get();
    for (final b in dirty) {
      try {
        RecordModel saved;
        if (b.file.isEmpty && b.data != null && !b.deleted) {
          // First upload: create with the image bytes + options (multipart).
          saved = await _pb.collection(_backgrounds).create(
            body: {
              'id': b.id,
              'owner': b.owner,
              'name': b.name,
              'opacity': b.opacity,
              'overlayColor': b.overlayColor,
              'overlayOpacity': b.overlayOpacity,
              'fit': b.fit,
              'repeat': b.repeat,
              'scale': b.scale,
              'deleted': false,
            },
            files: [
              http.MultipartFile.fromBytes('file', b.data!,
                  filename: 'bg_${b.id}.jpg'),
            ],
          );
        } else {
          // Options / soft-delete change on an existing record.
          saved = await _pb.collection(_backgrounds).update(b.id, body: {
            'name': b.name,
            'opacity': b.opacity,
            'overlayColor': b.overlayColor,
            'overlayOpacity': b.overlayOpacity,
            'fit': b.fit,
            'repeat': b.repeat,
            'scale': b.scale,
            'deleted': b.deleted,
          });
        }
        await (_db.update(_db.backgrounds)..where((t) => t.id.equals(b.id)))
            .write(BackgroundsCompanion(
          file: Value(saved.getStringValue('file')),
          created: Value(saved.getStringValue('created')),
          updated: Value(saved.getStringValue('updated')),
          dirty: const Value(false),
        ));
      } on ClientException catch (e) {
        if (e.statusCode == 404 && b.deleted) {
          await (_db.update(_db.backgrounds)..where((t) => t.id.equals(b.id)))
              .write(const BackgroundsCompanion(dirty: Value(false)));
        }
        // else: transient — leave dirty, retry next cycle.
      }
    }
  }

  Future<void> _pullBackgrounds() async {
    await _pull(_backgrounds, (rec) => _applyRecord(_backgrounds, rec),
        _localBackgroundUpdated);
  }

  Future<({String updated, bool dirty})?> _localBackgroundUpdated(
      String id) async {
    final row = await (_db.select(_db.backgrounds)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : (updated: row.updated, dirty: row.dirty);
  }

  Future<void> _downloadPendingBackgroundBytes() async {
    final pending = await (_db.select(_db.backgrounds)
          ..where((t) =>
              t.deleted.equals(false) &
              t.file.equals('').not() &
              t.data.isNull()))
        .get();
    for (final b in pending) {
      try {
        final rec = await _pb.collection(_backgrounds).getOne(b.id);
        final filename = rec.getStringValue('file');
        if (filename.isEmpty || rec.getBoolValue('deleted')) continue;
        final bytes = await _downloadFile(rec, filename);
        if (bytes != null) {
          await (_db.update(_db.backgrounds)..where((t) => t.id.equals(b.id)))
              .write(BackgroundsCompanion(data: Value(bytes)));
        }
      } on ClientException catch (e) {
        if (e.statusCode == 404) continue;
        rethrow;
      }
    }
  }

  /// Fetch backgrounds that local notes reference but we don't have yet —
  /// foreign ones used on shared notes (our own pull is owner-scoped). The
  /// backgrounds `viewRule` lets any signed-in user read one by id. Fetch-once:
  /// a row already present is left as-is.
  Future<void> _fetchReferencedBackgrounds() async {
    final notes = await _db.select(_db.notes).get();
    final referenced = <String>{
      for (final n in notes)
        if (n.background.isNotEmpty) n.background,
    };
    if (referenced.isEmpty) return;
    final have = {for (final b in await _db.select(_db.backgrounds).get()) b.id};
    for (final id in referenced) {
      if (have.contains(id)) continue;
      try {
        final rec = await _pb.collection(_backgrounds).getOne(id);
        await _applyRecord(_backgrounds, rec); // inserts + downloads bytes
      } on ClientException catch (e) {
        if (e.statusCode == 404) continue; // background gone
        rethrow;
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
        'background': n.background,
        'labels': _decodeIds(n.labels),
        'notebook': n.notebook,
        'lockedBy': n.lockedBy,
        'lockedAt': n.lockedAt,
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
    await _pull(_labels, (rec) => _applyRecord(_labels, rec), _localLabelUpdated);
  }

  // ---------------- Realtime (live updates while online) ----------------

  /// Apply a single record arriving over a realtime subscription, with the same
  /// last-write-wins guard the pull uses (never clobber a newer dirty local
  /// edit). A `delete` action removes the local row (hard delete). This is what
  /// makes another device's change show up on mobile *instantly* instead of
  /// waiting for the 30s pull — see [_localState]/[_applyRecord] for the mapping.
  Future<void> applyRealtimeRecord(
      String collection, RecordModel rec, String action) async {
    if (action == 'delete') {
      await _deleteLocal(collection, rec.id);
      return;
    }
    final serverUpdated = rec.getStringValue('updated');
    final local = await _localState(collection, rec.id);
    final keepLocal = local != null &&
        local.dirty &&
        local.updated.compareTo(serverUpdated) >= 0;
    if (!keepLocal) await _applyRecord(collection, rec);
  }

  Future<({String updated, bool dirty})?> _localState(
      String collection, String id) {
    return switch (collection) {
      _labels => _localLabelUpdated(id),
      _notebooks => _localNotebookUpdated(id),
      _notes => _localNoteUpdated(id),
      _items => _localItemUpdated(id),
      _attachments => _localAttachmentUpdated(id),
      _backgrounds => _localBackgroundUpdated(id),
      _ => Future.value(null),
    };
  }

  Future<void> _deleteLocal(String collection, String id) async {
    switch (collection) {
      case _labels:
        await (_db.delete(_db.labels)..where((t) => t.id.equals(id))).go();
      case _notebooks:
        await (_db.delete(_db.notebooks)..where((t) => t.id.equals(id))).go();
      case _notes:
        await (_db.delete(_db.notes)..where((t) => t.id.equals(id))).go();
      case _items:
        await (_db.delete(_db.checklistItems)..where((t) => t.id.equals(id)))
            .go();
      case _attachments:
        await (_db.delete(_db.attachments)..where((t) => t.id.equals(id))).go();
      case _backgrounds:
        await (_db.delete(_db.backgrounds)..where((t) => t.id.equals(id))).go();
    }
  }

  /// Upsert one server record into drift (shared by pull + realtime). Mirrors
  /// the per-collection field mapping; keep in sync with the push bodies.
  Future<void> _applyRecord(String collection, RecordModel rec) async {
    switch (collection) {
      case _labels:
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
      case _notebooks:
        await _db.into(_db.notebooks).insertOnConflictUpdate(NotebooksCompanion(
              id: Value(rec.id),
              owner: Value(rec.getStringValue('owner')),
              name: Value(rec.getStringValue('name')),
              sharedWith:
                  Value(jsonEncode(rec.getListValue<String>('sharedWith'))),
              hiddenFromAll: Value(rec.getBoolValue('hidden_from_all')),
              deleted: Value(rec.getBoolValue('deleted')),
              created: Value(rec.getStringValue('created')),
              updated: Value(rec.getStringValue('updated')),
              dirty: const Value(false),
            ));
      case _notes:
        await _db.into(_db.notes).insertOnConflictUpdate(NotesCompanion(
              id: Value(rec.id),
              owner: Value(rec.getStringValue('owner')),
              type: Value(rec.getStringValue('type')),
              title: Value(rec.getStringValue('title')),
              body: Value(rec.getStringValue('body')),
              pinned: Value(rec.getBoolValue('pinned')),
              archived: Value(rec.getBoolValue('archived')),
              color: Value(rec.getStringValue('color')),
              background: Value(rec.getStringValue('background')),
              labels: Value(jsonEncode(rec.getListValue<String>('labels'))),
              notebook: Value(rec.getStringValue('notebook')),
              lockedBy: Value(rec.getStringValue('lockedBy')),
              lockedAt: Value(rec.getStringValue('lockedAt')),
              deleted: Value(rec.getBoolValue('deleted')),
              created: Value(rec.getStringValue('created')),
              updated: Value(rec.getStringValue('updated')),
              dirty: const Value(false),
            ));
      case _items:
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
      case _attachments:
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
      case _backgrounds:
        await _db
            .into(_db.backgrounds)
            .insertOnConflictUpdate(BackgroundsCompanion(
              id: Value(rec.id),
              owner: Value(rec.getStringValue('owner')),
              name: Value(rec.getStringValue('name')),
              file: Value(rec.getStringValue('file')),
              opacity: Value(_numField(rec, 'opacity', 1)),
              overlayColor: Value(rec.getStringValue('overlayColor')),
              overlayOpacity: Value(_numField(rec, 'overlayOpacity', 0)),
              fit: Value(rec.getStringValue('fit').isEmpty
                  ? 'cover'
                  : rec.getStringValue('fit')),
              repeat: Value(rec.getStringValue('repeat').isEmpty
                  ? 'none'
                  : rec.getStringValue('repeat')),
              scale: Value(_numField(rec, 'scale', 1)),
              deleted: Value(rec.getBoolValue('deleted')),
              created: Value(rec.getStringValue('created')),
              updated: Value(rec.getStringValue('updated')),
              dirty: const Value(false),
            ));
        final bgFile = rec.getStringValue('file');
        if (bgFile.isEmpty || rec.getBoolValue('deleted')) return;
        final existingBg = await (_db.select(_db.backgrounds)
              ..where((t) => t.id.equals(rec.id)))
            .getSingleOrNull();
        if (existingBg?.data != null) return;
        final bgBytes = await _downloadFile(rec, bgFile);
        if (bgBytes != null) {
          await (_db.update(_db.backgrounds)..where((t) => t.id.equals(rec.id)))
              .write(BackgroundsCompanion(data: Value(bgBytes)));
        }
    }
  }

  /// A PocketBase number field as a double, falling back when it reads 0
  /// (unset). opacity/scale fall back to 1; overlayOpacity to 0.
  double _numField(RecordModel rec, String field, double fallback) {
    final v = rec.getDoubleValue(field);
    return v == 0 ? fallback : v;
  }

  Future<void> _pullNotebooks() async {
    await _pull(
        _notebooks, (rec) => _applyRecord(_notebooks, rec), _localNotebookUpdated);
  }

  /// Remove local copies of shared notebooks I've lost access to (the owner
  /// unshared the notebook or removed me). Such notebooks were owned by *another*
  /// account and stop being returned by the server once I'm no longer a member;
  /// the pull can't detect that on its own, so reconcile against the full set of
  /// notebook ids the server still lets me read. My own notebooks (and the
  /// offline `local` sentinel) are never touched.
  Future<void> _reconcileSharedNotebooks() async {
    final myId = _pb.authStore.record?.id ?? '';
    if (myId.isEmpty) return;
    final accessible = <String>{
      for (final r in await _pb
          .collection(_notebooks)
          .getFullList(batch: 500, fields: 'id'))
        r.id,
    };
    final local = await _db.select(_db.notebooks).get();
    for (final nb in local) {
      final foreign = nb.owner != myId && nb.owner != AppConfig.localOwner;
      if (!foreign || accessible.contains(nb.id)) continue;
      // I was removed from this notebook — purge it and its notes locally.
      final notes = await (_db.select(_db.notes)
            ..where((t) => t.notebook.equals(nb.id)))
          .get();
      for (final n in notes) {
        await (_db.delete(_db.checklistItems)
              ..where((t) => t.note.equals(n.id)))
            .go();
        await (_db.delete(_db.attachments)..where((t) => t.note.equals(n.id)))
            .go();
        await (_db.delete(_db.notes)..where((t) => t.id.equals(n.id))).go();
      }
      await (_db.delete(_db.notebooks)..where((t) => t.id.equals(nb.id))).go();
    }
  }

  /// Full-fetch the content of every notebook shared *with* me (foreign-owned,
  /// present locally). The incremental notes/items/attachments pulls are
  /// cursor-based, so a record that becomes accessible *after* its `updated`
  /// (a notebook (re)shared later, or restored notes carrying an old timestamp)
  /// would never reappear in the cursor window. Re-applying the full set by
  /// notebook closes that gap; LWW in [_applyRecord] never clobbers local dirty
  /// edits, and already-current rows are cheap no-ops.
  Future<void> _pullSharedNotebookContent() async {
    final myId = _pb.authStore.record?.id ?? '';
    if (myId.isEmpty) return;
    for (final nb in await _db.select(_db.notebooks).get()) {
      final foreign = nb.owner != myId && nb.owner != AppConfig.localOwner;
      if (!foreign || nb.deleted) continue;
      final nbId = nb.id.replaceAll("'", "");
      for (final rec
          in await _pb.collection(_notes).getFullList(batch: 200, filter: "notebook = '$nbId'")) {
        await _applyRecord(_notes, rec);
      }
      for (final rec in await _pb
          .collection(_items)
          .getFullList(batch: 500, filter: "note.notebook = '$nbId'")) {
        await _applyRecord(_items, rec);
      }
      for (final rec in await _pb
          .collection(_attachments)
          .getFullList(batch: 200, filter: "note.notebook = '$nbId'")) {
        await _applyRecord(_attachments, rec);
      }
    }
  }

  /// Remove local copies of individual notes I've lost access to. The
  /// notebook-level reconcile only covers whole notebooks I was removed from; a
  /// note can also leave my reach on its own — e.g. another member *claimed* a
  /// note out of a shared notebook, reassigning its `owner` to themselves. Such
  /// a note stops being returned by the server but the pull can't see that, so
  /// reconcile against the full set of note ids the server still lets me read.
  ///
  /// Only *foreign*-owned notes are eligible (owner != me and not the offline
  /// `local` sentinel) — my own notes and locally-created ones are never
  /// touched. Notes in shared notebooks I'm still a member of stay accessible,
  /// so they're in the set and survive.
  Future<void> _reconcileSharedNotes() async {
    final myId = _pb.authStore.record?.id ?? '';
    if (myId.isEmpty) return;
    final accessible = <String>{
      for (final r in await _pb
          .collection(_notes)
          .getFullList(batch: 500, fields: 'id'))
        r.id,
    };
    final local = await _db.select(_db.notes).get();
    for (final n in local) {
      final foreign = n.owner != myId && n.owner != AppConfig.localOwner;
      if (!foreign || accessible.contains(n.id)) continue;
      // I lost access to this note — purge it and its children locally.
      await (_db.delete(_db.checklistItems)..where((t) => t.note.equals(n.id)))
          .go();
      await (_db.delete(_db.attachments)..where((t) => t.note.equals(n.id)))
          .go();
      await (_db.delete(_db.notes)..where((t) => t.id.equals(n.id))).go();
    }
  }

  Future<void> _pullNotes() async {
    await _pull(_notes, (rec) => _applyRecord(_notes, rec), _localNoteUpdated);
  }

  Future<void> _pullItems() async {
    await _pull(_items, (rec) => _applyRecord(_items, rec), _localItemUpdated);
  }

  Future<void> _pullAttachments() async {
    await _pull(_attachments, (rec) => _applyRecord(_attachments, rec),
        _localAttachmentUpdated);
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
