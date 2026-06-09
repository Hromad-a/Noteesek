@Tags(['integration'])
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/sync/sync_engine.dart';

const baseUrl = 'http://localhost:8090';

void main() {
  late PocketBase pb;
  late String userId;

  setUpAll(() async {
    pb = PocketBase(baseUrl);
    final email = 'nbrepro_${DateTime.now().microsecondsSinceEpoch}@example.com';
    await pb.collection('users').create(body: {
      'email': email,
      'password': 'password123',
      'passwordConfirm': 'password123',
    });
    await pb.collection('users').authWithPassword(email, 'password123');
    userId = pb.authStore.record!.id;
  });

  test('notebooks created on device A pull down to a fresh device B', () async {
    // Device A: a default notebook + two user notebooks, then sync up.
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = LocalNotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);

    final defId = await repoA.ensureDefaultNotebook();
    final workId = await repoA.createNotebook('Work');
    final homeId = await repoA.createNotebook('Home');

    expect(await engineA.syncOnce(), isTrue);

    // Confirm they're on the server.
    final serverList = await pb.collection('notebooks').getFullList();
    expect(serverList.map((r) => r.id),
        containsAll([defId, workId, homeId]));

    // Device B: fresh DB, same account → pull.
    final dbB = AppDatabase(NativeDatabase.memory());
    final engineB = SyncEngine(dbB, pb);
    final repoB = LocalNotesRepository(dbB, userId);

    await engineB.syncOnce();

    final nbB = await repoB.watchNotebooks().first;
    expect(nbB.map((n) => n.name), containsAll(['Notebook', 'Work', 'Home']),
        reason: 'all notebooks should have pulled down to the fresh device');
    expect(nbB.map((n) => n.id), containsAll([defId, workId, homeId]));

    await dbA.close();
    await dbB.close();
  });

  test('fresh sign-in race: ensureDefaultNotebook before sync still keeps others',
      () async {
    // Device A: default + two user notebooks on the server (unique names).
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = LocalNotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);
    await repoA.ensureDefaultNotebook();
    await repoA.createNotebook('Alpha');
    await repoA.createNotebook('Beta');
    await engineA.syncOnce();

    // Device B (fresh): mimic the real sign-in order —
    //   ensureDefaultNotebook() (creates a LOCAL default) BEFORE the first pull,
    //   then sync, then ensureDefaultNotebook() again (reconcile).
    final dbB = AppDatabase(NativeDatabase.memory());
    final repoB = LocalNotesRepository(dbB, userId);
    final engineB = SyncEngine(dbB, pb);

    await repoB.ensureDefaultNotebook(); // local default, dirty
    await engineB.syncOnce(); // push local default, pull server notebooks
    await repoB.ensureDefaultNotebook(); // reconcile duplicate defaults

    final names = (await repoB.watchNotebooks().first).map((n) => n.name);
    expect(names, containsAll(['Alpha', 'Beta']),
        reason: 'user notebooks must survive the default-reconciliation race');
    expect(names.where((n) => n == 'Notebook').length, 1,
        reason: 'exactly one default after reconciliation');

    await dbA.close();
    await dbB.close();
  });
}
