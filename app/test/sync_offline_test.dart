import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/providers.dart';
import 'package:noteesek/sync/sync_controller.dart';
import 'package:noteesek/sync/sync_engine.dart';

/// A sync engine that always fails as if the server is unreachable.
class _OfflineEngine extends SyncEngine {
  _OfflineEngine(super.db, super.pb);

  @override
  Future<bool> syncOnce() async =>
      throw ClientException(statusCode: 0, url: Uri.parse('http://down'));
}

void main() {
  test('unreachable server is non-fatal: outcome=unreachable, reachable=false',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final engine = _OfflineEngine(db, PocketBase('http://localhost:1'));

    final container = ProviderContainer(overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      databaseProvider.overrideWithValue(db),
      syncEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(container.dispose);

    final outcome = await container
        .read(syncControllerProvider.notifier)
        .syncNow(manual: true);

    expect(outcome, SyncOutcome.unreachable);
    final status = container.read(syncControllerProvider);
    expect(status.reachable, isFalse);
    expect(status.syncing, isFalse);
    expect(status.message, 'Server not responding');
  });

  test('not connected => notConnected outcome', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final engine = _OfflineEngine(db, PocketBase('http://localhost:1'));

    final container = ProviderContainer(overrides: [
      isAuthenticatedProvider.overrideWithValue(false),
      databaseProvider.overrideWithValue(db),
      syncEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(container.dispose);

    final outcome =
        await container.read(syncControllerProvider.notifier).syncNow();
    expect(outcome, SyncOutcome.notConnected);
  });
}
