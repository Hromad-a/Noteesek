@Tags(['integration'])
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/config/app_config.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/sync/reconciliation_service.dart';
import 'package:noteesek/sync/sync_engine.dart';

const baseUrl = 'http://localhost:8090';

Future<(PocketBase, String)> _newAccount(String tag) async {
  final pb = PocketBase(baseUrl);
  final email = '${tag}_${DateTime.now().microsecondsSinceEpoch}@example.com';
  await pb.collection('users').create(body: {
    'email': email,
    'password': 'password123',
    'passwordConfirm': 'password123',
  });
  await pb.collection('users').authWithPassword(email, 'password123');
  return (pb, pb.authStore.record!.id);
}

Future<int> _dirtyCount(AppDatabase db) async {
  final n =
      (await (db.select(db.notes)..where((t) => t.dirty.equals(true))).get())
          .length;
  final nb = (await (db.select(db.notebooks)..where((t) => t.dirty.equals(true)))
          .get())
      .length;
  return n + nb;
}

void main() {
  // Cross-account merge is intentionally NOT supported on a shared server. When
  // the device holds another account's notes and you sign into a different
  // account, the only path is "wipe this device + load the account fresh".
  test('signing into account B with account A data wipes local and loads B',
      () async {
    final (pbA, userA) = await _newAccount('xacctA');
    final (pbB, userB) = await _newAccount('xacctB');

    final db = AppDatabase(NativeDatabase.memory());

    // Device is synced with account A: 3 notes.
    final repoA = LocalNotesRepository(db, userA);
    final engineA = SyncEngine(db, pbA);
    for (var i = 0; i < 3; i++) {
      final id = await repoA.createNote(type: 'text');
      await repoA.updateNoteFields(id, title: 'A note $i');
    }
    await engineA.syncOnce();

    // Then signed out and made an offline note (owner = local sentinel).
    final repoLocal = LocalNotesRepository(db, AppConfig.localOwner);
    final off = await repoLocal.createNote(type: 'text');
    await repoLocal.updateNoteFields(off, title: 'offline note');

    // Account B already has 2 notes of its own (made on another device).
    final dbSeed = AppDatabase(NativeDatabase.memory());
    final repoSeed = LocalNotesRepository(dbSeed, userB);
    final engineSeed = SyncEngine(dbSeed, pbB);
    for (var i = 0; i < 2; i++) {
      final id = await repoSeed.createNote(type: 'text');
      await repoSeed.updateNoteFields(id, title: 'B note $i');
    }
    await engineSeed.syncOnce();
    await dbSeed.close();

    // Sign into B on the device → it holds account A's data, which is foreign.
    final repoB = LocalNotesRepository(db, userB);
    final engineB = SyncEngine(db, pbB);
    expect(await repoB.hasForeignAccountData(userB), isTrue,
        reason: "account A's notes are foreign to B");

    // The only offered action: wipe local + pull B.
    final service = ReconciliationService(db, pbB, engineB);
    await service.keepServerReplace();

    // Device now mirrors account B exactly — A's notes and the offline note are
    // gone, B's 2 notes are present, nothing left dirty.
    final titles = (await repoB.watchActive().first).map((n) => n.title).toSet();
    expect(titles, {'B note 0', 'B note 1'});
    expect(await _dirtyCount(db), 0);
    expect(await repoB.hasForeignAccountData(userB), isFalse);

    // Both servers are untouched by the wipe.
    final aServer =
        await pbA.collection('notes').getFullList(filter: 'deleted = false');
    expect(aServer.length, 3, reason: "A's server is not modified");
    final bServer =
        await pbB.collection('notes').getFullList(filter: 'deleted = false');
    expect(bServer.length, 2, reason: "B's server is not modified");

    await db.close();
  });
}
