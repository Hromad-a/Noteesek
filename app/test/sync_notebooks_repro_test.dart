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
    // Device A: two notebooks, then sync up.
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = LocalNotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);

    final workId = await repoA.createNotebook('Work');
    final homeId = await repoA.createNotebook('Home');

    expect(await engineA.syncOnce(), isTrue);

    // Confirm they're on the server.
    final serverList = await pb.collection('notebooks').getFullList();
    expect(serverList.map((r) => r.id), containsAll([workId, homeId]));

    // Device B: fresh DB, same account → pull.
    final dbB = AppDatabase(NativeDatabase.memory());
    final engineB = SyncEngine(dbB, pb);
    final repoB = LocalNotesRepository(dbB, userId);

    await engineB.syncOnce();

    final nbB = await repoB.watchNotebooks().first;
    expect(nbB.map((n) => n.name), containsAll(['Work', 'Home']),
        reason: 'all notebooks should have pulled down to the fresh device');
    expect(nbB.map((n) => n.id), containsAll([workId, homeId]));

    await dbA.close();
    await dbB.close();
  });

  test('sign-in merges offline-local data with different server data (union)',
      () async {
    // --- Server side: a notebook + a note created on "another device". ---
    final dbS = AppDatabase(NativeDatabase.memory());
    final repoS = LocalNotesRepository(dbS, userId);
    final engineS = SyncEngine(dbS, pb);
    final serverNb = await repoS.createNotebook('ServerNotebook');
    final serverNote = await repoS.createNote(type: 'text', notebook: serverNb);
    await repoS.updateNoteFields(serverNote, title: 'from server');
    await engineS.syncOnce();

    // --- New phone used OFFLINE (no account): owner = the local sentinel. ---
    final dbB = AppDatabase(NativeDatabase.memory());
    final repoLocal = LocalNotesRepository(dbB, AppConfig.localOwner);
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

    // Local now holds BOTH sets of notebooks + notes (union).
    final nbNames = (await repoB.watchNotebooks().first).map((n) => n.name);
    expect(nbNames, containsAll(['ServerNotebook', 'LocalNotebook']));

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

  test('signing into a different account does not leak the first account data',
      () async {
    // Account A (the suite user): create + sync a note, so the local DB mirrors
    // account A and is clean (dirty = false).
    final db = AppDatabase(NativeDatabase.memory());
    final repoA = LocalNotesRepository(db, userId);
    final engineA = SyncEngine(db, pb);
    final nA = await repoA.createNote(type: 'text');
    await repoA.updateNoteFields(nA, title: 'account A secret');
    await engineA.syncOnce();

    // "Sign out" keeps the data on the device. Now sign in as a DIFFERENT
    // account B on the SAME local DB.
    final pbB = PocketBase(baseUrl);
    final emailB = 'acctB_${DateTime.now().microsecondsSinceEpoch}@example.com';
    await pbB.collection('users').create(body: {
      'email': emailB,
      'password': 'password123',
      'passwordConfirm': 'password123',
    });
    await pbB.collection('users').authWithPassword(emailB, 'password123');
    final userB = pbB.authStore.record!.id;

    final repoB = LocalNotesRepository(db, userB);
    final engineB = SyncEngine(db, pbB);
    await repoB.claimLocalNotes(userB); // only claims owner='local' rows (none)
    await engineB.syncOnce(); // push (nothing dirty) + pull B's (empty)

    // Account B's server must NOT contain account A's note.
    final bServer = await pbB.collection('notes').getFullList();
    expect(bServer.map((r) => r.getStringValue('title')),
        isNot(contains('account A secret')),
        reason: "first account's data must not be pushed to the second");

    // Mobile local views are intentionally NOT owner-scoped (see CLAUDE.md):
    // watchActive() shows every row on the device regardless of owner, so A's
    // note stays visible after signing into B. That is by design — the leak we
    // guard against is server-side (asserted above), not device-local.

    // A's data is still on the device, tagged with A's owner.
    final all = await db.select(db.notes).get();
    expect(
        all.where((n) => n.owner == userId && n.title == 'account A secret'),
        isNotEmpty);

    await db.close();
  });

  test('ReconciliationService.keepServerReplace discards local, pulls server',
      () async {
    // Server: a notebook + note on the account.
    final dbS = AppDatabase(NativeDatabase.memory());
    final repoS = LocalNotesRepository(dbS, userId);
    final engineS = SyncEngine(dbS, pb);
    await repoS.createNotebook('KSServerNb');
    final sNote = await repoS.createNote(type: 'text');
    await repoS.updateNoteFields(sNote, title: 'ks server note');
    await engineS.syncOnce();

    // Device with offline-only data (not on the server).
    final db = AppDatabase(NativeDatabase.memory());
    final repoLocal = LocalNotesRepository(db, AppConfig.localOwner);
    await repoLocal.createNotebook('KSLocalNb');
    final lNote = await repoLocal.createNote(type: 'text');
    await repoLocal.updateNoteFields(lNote, title: 'ks local note');

    final repoB = LocalNotesRepository(db, userId);
    final engineB = SyncEngine(db, pb);
    final service = ReconciliationService(db, pb, engineB);

    final summary = await service.inspect(userId);
    expect(summary.localOnly, greaterThanOrEqualTo(2),
        reason: 'offline notebook + note are local-only');

    await service.keepServerReplace();

    final nbNames = (await repoB.watchNotebooks().first).map((n) => n.name);
    expect(nbNames, contains('KSServerNb'));
    expect(nbNames, isNot(contains('KSLocalNb')),
        reason: 'local-only data is discarded');
    final titles = (await repoB.watchActive().first).map((n) => n.title);
    expect(titles, contains('ks server note'));
    expect(titles, isNot(contains('ks local note')));

    await dbS.close();
    await db.close();
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
      'deleted': false,
    });
    expect(rec.getStringValue('owner'), userId);
  });
}
