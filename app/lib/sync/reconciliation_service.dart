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
  /// server down) for a union on both sides. [combineSameName] (Phase 4) is
  /// accepted but not yet applied.
  Future<void> merge({
    required String userId,
    bool combineSameName = false,
  }) async {
    await _repo.reownAll(userId);
    await _engine.syncOnce();
    // Reconcile duplicate default notebooks (one from each side), then settle.
    await _repo.ensureDefaultNotebook();
    await _engine.syncOnce();
  }

  /// Keep server only: discard ALL local data (wipe + reset cursors), then pull
  /// the account fresh. Local-only records are lost (the guarded choice).
  Future<void> keepServerReplace() async {
    await _db.wipeAllLocal();
    await _engine.syncOnce(); // cursors cleared → full pull
    await _repo.ensureDefaultNotebook();
    await _engine.syncOnce();
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
              t.owner.isNotValue(userId) &
              t.deleted.equals(false) &
              t.isDefault.equals(false)))
        .get();
    return notes.length + nbs.length;
  }
}
