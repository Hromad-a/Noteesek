@Tags(['integration'])
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/config/app_config.dart';
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

  test('sign-in merges offline-local data with different server data (union)',
      () async {
    // --- Server side: a notebook + a note created on "another device". ---
    final dbS = AppDatabase(NativeDatabase.memory());
    final repoS = LocalNotesRepository(dbS, userId);
    final engineS = SyncEngine(dbS, pb);
    await repoS.ensureDefaultNotebook(); // server default
    final serverNb = await repoS.createNotebook('ServerNotebook');
    final serverNote = await repoS.createNote(type: 'text', notebook: serverNb);
    await repoS.updateNoteFields(serverNote, title: 'from server');
    await engineS.syncOnce();

    // --- New phone used OFFLINE (no account): owner = the local sentinel. ---
    final dbB = AppDatabase(NativeDatabase.memory());
    final repoLocal = LocalNotesRepository(dbB, AppConfig.localOwner);
    await repoLocal.ensureDefaultNotebook(); // a *local* default
    final localNb = await repoLocal.createNotebook('LocalNotebook');
    final localNote =
        await repoLocal.createNote(type: 'text', notebook: localNb);
    await repoLocal.updateNoteFields(localNote, title: 'from phone');

    // --- Sign in: claim local rows to the account, sync, reconcile defaults
    //     (mirrors login_screen + the notes screen's ensureDefaultNotebook). ---
    final repoB = LocalNotesRepository(dbB, userId);
    final engineB = SyncEngine(dbB, pb);
    await repoB.claimLocalNotes(userId);
    await engineB.syncOnce();
    await repoB.ensureDefaultNotebook();
    await engineB.syncOnce(); // push the default reconciliation, settle

    // Local now holds BOTH sets of notebooks + notes (union).
    final nbNames = (await repoB.watchNotebooks().first).map((n) => n.name);
    expect(nbNames, containsAll(['ServerNotebook', 'LocalNotebook']));
    expect(nbNames.where((n) => n == 'Notebook').length, 1,
        reason: 'the two defaults reconcile to one');

    final noteTitles =
        (await repoB.watchActive().first).map((n) => n.title).toList();
    expect(noteTitles, containsAll(['from server', 'from phone']));

    // And the server has both too (the phone's data was pushed up).
    final serverNotes = await pb.collection('notes').getFullList();
    expect(serverNotes.map((r) => r.getStringValue('title')),
        containsAll(['from server', 'from phone']));

    await dbS.close();
    await dbB.close();
  });

  test('server stamps owner on create regardless of client value (owner.pb.js)',
      () async {
    // A blank/wrong client owner must NOT fail the create: the server forces
    // owner = the authenticated user. (Against a server without owner.pb.js this
    // create would be rejected by the createRule, so this also verifies the hook
    // is deployed.)
    final rec = await pb.collection('notebooks').create(body: {
      'owner': '',
      'name': 'ForcedOwner',
      'is_default': false,
      'deleted': false,
    });
    expect(rec.getStringValue('owner'), userId);
  });
}
