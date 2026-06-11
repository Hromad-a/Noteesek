import 'package:drift/drift.dart';
import 'package:pocketbase/pocketbase.dart';

import '../data/local/database.dart';
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

/// Runs the sign-in reconciliation flow (mobile only). The device's offline
/// `local` data is claimed into the account by the normal sign-in path; this
/// service handles the one case that needs a choice: when the device holds
/// *another account's* data, [inspect] summarises it and [keepServerReplace]
/// wipes the device and loads the account fresh (see
/// docs/sign-in-reconciliation.md).
class ReconciliationService {
  ReconciliationService(this._db, this._pb, this._engine);

  final AppDatabase _db;
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

  /// Replace this device with the account: discard ALL local data (wipe + reset
  /// cursors), then pull the account fresh. Any local-only/foreign data on the
  /// device is lost — this is the guarded choice shown when the device holds
  /// another account's data.
  Future<void> keepServerReplace() async {
    await _db.wipeAllLocal();
    await _engine.syncOnce(); // cursors cleared → full pull
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
