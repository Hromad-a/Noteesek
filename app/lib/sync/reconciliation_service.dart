import 'package:drift/drift.dart';
import 'package:pocketbase/pocketbase.dart';

import '../data/local/database.dart';
import '../data/notes_repository.dart';
import 'sync_engine.dart';

/// A snapshot comparing the device's local data with the account's server data,
/// shown on the reconciliation screen so the user can choose what to do.
class ReconcileSummary {
  const ReconcileSummary({
    required this.localNotebooks,
    required this.localNotes,
    required this.foreignItems,
    required this.serverNotebooks,
    required this.serverNotes,
    required this.localOnly,
    required this.serverOnly,
  });

  /// Local (this device) counts — across all owners, non-deleted.
  final int localNotebooks;
  final int localNotes;

  /// How many of the local items come from another account or offline use
  /// (foreign notes + foreign non-default notebooks).
  final int foreignItems;

  /// Server (this account) counts — non-deleted.
  final int serverNotebooks;
  final int serverNotes;

  /// Notes+notebooks present on the device but NOT on the server (by id). These
  /// are what "Keep server only" would permanently lose.
  final int localOnly;

  /// Notes+notebooks present on the server but NOT on the device (by id). These
  /// are what "Keep local only" would delete from the server.
  final int serverOnly;
}

/// Runs the sign-in reconciliation strategies (mobile only). Phase 1 implements
/// [inspect] + [merge]; [keepLocalMirror] / [keepServerReplace] arrive in later
/// phases (see docs/sign-in-reconciliation.md).
class ReconciliationService {
  ReconciliationService(this._db, this._repo, this._pb, this._engine);

  final AppDatabase _db;
  final NotesRepository _repo;
  final PocketBase _pb;
  final SyncEngine _engine;

  /// Local vs server snapshot for the chooser. Compares note + notebook id sets
  /// so the destructive options can show exactly how much each would remove.
  Future<ReconcileSummary> inspect(String userId) async {
    final localNoteIds = await _localIds(_db.notes, _db.notes.deleted);
    final localNbIds = await _localIds(_db.notebooks, _db.notebooks.deleted);
    final serverNoteIds = await _serverIds('notes');
    final serverNbIds = await _serverIds('notebooks');

    final localOnly = localNoteIds.difference(serverNoteIds).length +
        localNbIds.difference(serverNbIds).length;
    final serverOnly = serverNoteIds.difference(localNoteIds).length +
        serverNbIds.difference(localNbIds).length;

    return ReconcileSummary(
      localNotebooks: localNbIds.length,
      localNotes: localNoteIds.length,
      foreignItems: await _countForeign(userId),
      serverNotebooks: serverNbIds.length,
      serverNotes: serverNoteIds.length,
      localOnly: localOnly,
      serverOnly: serverOnly,
    );
  }

  /// Merge: re-own all local data into [userId], then sync (push local up, pull
  /// server down) for a union on both sides. When [combineSameName] is set,
  /// notebooks that share a name are combined into one after the union.
  Future<void> merge({
    required String userId,
    bool combineSameName = false,
  }) async {
    await _repo.reownAll(userId);
    await _engine.syncOnce(); // union: both sides' notebooks/notes are now local
    if (combineSameName) {
      await _repo.combineNotebooksByName();
      await _engine.syncOnce();
    }
  }

  /// Keep server only: discard ALL local data (wipe + reset cursors), then pull
  /// the account fresh. Local-only records are lost (the guarded choice).
  Future<void> keepServerReplace() async {
    await _db.wipeAllLocal();
    await _engine.syncOnce(); // cursors cleared → full pull
  }

  /// Keep local only: make the server exactly match this device. Re-own + push
  /// local up (push-only so server data isn't pulled back), then soft-delete the
  /// server records that aren't local (the guarded choice), then settle.
  Future<void> keepLocalMirror({required String userId}) async {
    await _repo.reownAll(userId);
    // Snapshot what's on the server but not local, BEFORE pushing (the push adds
    // local ids to the server, which must not be deleted).
    final serverOnly = await _serverOnlyByCollection();
    await _engine.syncOnce(pushOnly: true);
    for (final entry in serverOnly.entries) {
      for (final id in entry.value) {
        try {
          await _pb.collection(entry.key).update(id, body: {'deleted': true});
        } on ClientException catch (e) {
          if (e.statusCode != 404) rethrow; // already gone → fine
        }
      }
    }
    await _engine.syncOnce(); // pull the tombstones + our pushes, settle
  }

  /// Per collection, the ids of live server records not present locally — what
  /// the mirror deletes.
  Future<Map<String, Set<String>>> _serverOnlyByCollection() async {
    final tables = <String, (TableInfo, GeneratedColumn<bool>)>{
      'notes': (_db.notes, _db.notes.deleted),
      'notebooks': (_db.notebooks, _db.notebooks.deleted),
      'labels': (_db.labels, _db.labels.deleted),
      'checklist_items': (_db.checklistItems, _db.checklistItems.deleted),
      'attachments': (_db.attachments, _db.attachments.deleted),
    };
    final result = <String, Set<String>>{};
    for (final entry in tables.entries) {
      final (table, deletedCol) = entry.value;
      final local = await _localIds(table, deletedCol);
      final server = await _serverIds(entry.key);
      result[entry.key] = server.difference(local);
    }
    return result;
  }

  // ---- helpers ----

  /// Ids of non-deleted rows in [table] (by its [deletedCol]).
  Future<Set<String>> _localIds(
      TableInfo table, GeneratedColumn<bool> deletedCol) async {
    final rows = await (_db.select(table)
          ..where((_) => deletedCol.equals(false)))
        .get();
    return {for (final r in rows) (r as dynamic).id as String};
  }

  /// Ids of non-deleted server records in [collection] (fetches the id only).
  Future<Set<String>> _serverIds(String collection) async {
    final recs = await _pb.collection(collection).getFullList(
          batch: 500,
          fields: 'id',
          filter: 'deleted = false',
        );
    return {for (final r in recs) r.id};
  }

  Future<int> _countForeign(String userId) async {
    final notes = await (_db.select(_db.notes)
          ..where((t) => t.owner.isNotValue(userId) & t.deleted.equals(false)))
        .get();
    final nbs = await (_db.select(_db.notebooks)
          ..where((t) =>
              t.owner.isNotValue(userId) & t.deleted.equals(false)))
        .get();
    return notes.length + nbs.length;
  }
}
