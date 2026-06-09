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

  /// Local vs server counts for the chooser. Server counts come from
  /// `totalItems` on a 1-row list query; local counts from the drift DB.
  Future<ReconcileSummary> inspect(String userId) async {
    final localNotes =
        await _countLive(_db.notes, _db.notes.deleted);
    final localNotebooks =
        await _countLive(_db.notebooks, _db.notebooks.deleted);
    final foreignItems = await _countForeign(userId);
    final serverNotes = await _serverCount('notes');
    final serverNotebooks = await _serverCount('notebooks');
    return ReconcileSummary(
      localNotebooks: localNotebooks,
      localNotes: localNotes,
      foreignItems: foreignItems,
      serverNotebooks: serverNotebooks,
      serverNotes: serverNotes,
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

  // ---- helpers ----

  /// Counts non-deleted rows in [table] using its [deletedCol].
  Future<int> _countLive(
      TableInfo table, GeneratedColumn<bool> deletedCol) async {
    final c = countAll(filter: deletedCol.equals(false));
    final row = await (_db.selectOnly(table)..addColumns([c])).getSingle();
    return row.read(c) ?? 0;
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

  Future<int> _serverCount(String collection) async {
    final res = await _pb.collection(collection).getList(
          page: 1,
          perPage: 1,
          filter: 'deleted = false',
        );
    return res.totalItems;
  }
}
