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
  final l =
      (await (db.select(db.labels)..where((t) => t.dirty.equals(true))).get())
          .length;
  final ci = (await (db.select(db.checklistItems)
              ..where((t) => t.dirty.equals(true)))
          .get())
      .length;
  return n + nb + l + ci;
}

void main() {
  // The regression: on a shared server another account's notes can't be
  // re-owned in place (their ids are taken), so the old reconciliation left
  // them permanently dirty. reownAll now re-ids them into fresh copies.
  test('merging another account\'s notes into a new account is not stranded',
      () async {
    final (pbA, userA) = await _newAccount('xacctA');
    final (pbB, userB) = await _newAccount('xacctB');

    final db = AppDatabase(NativeDatabase.memory());

    // Account A: a notebook + 3 notes (one in the notebook), synced up.
    final repoA = LocalNotesRepository(db, userA);
    final engineA = SyncEngine(db, pbA);
    final nbA = await repoA.createNotebook('Work');
    final inNb = await repoA.createNote(type: 'text', notebook: nbA);
    await repoA.updateNoteFields(inNb, title: 'A note in notebook');
    for (var i = 0; i < 2; i++) {
      final id = await repoA.createNote(type: 'text');
      await repoA.updateNoteFields(id, title: 'A note $i');
    }
    await engineA.syncOnce();
    expect(await _dirtyCount(db), 0, reason: 'A synced clean');

    // Sign out, add a local (offline) note.
    final repoLocal = LocalNotesRepository(db, AppConfig.localOwner);
    final localNoteId = await repoLocal.createNote(type: 'text');
    await repoLocal.updateNoteFields(localNoteId, title: 'offline note');

    // Sign into the empty account B → merge.
    final repoB = LocalNotesRepository(db, userB);
    final engineB = SyncEngine(db, pbB);
    final svcB = ReconciliationService(db, repoB, pbB, engineB);
    await svcB.merge(userId: userB, combineSameName: true);

    // Nothing stranded, and B now holds copies of all four notes + the notebook.
    expect(await _dirtyCount(db), 0,
        reason: 'no row should stay dirty after the merge');

    final bNotes =
        await pbB.collection('notes').getFullList(filter: 'deleted = false');
    expect(bNotes.length, 4, reason: 'B gets the 3 A-notes + the offline note');
    expect(bNotes.map((r) => r.getStringValue('title')),
        containsAll(['A note in notebook', 'A note 0', 'A note 1', 'offline note']));

    final bNbs =
        await pbB.collection('notebooks').getFullList(filter: 'deleted = false');
    expect(bNbs.map((r) => r.getStringValue('name')), contains('Work'));

    // The copied note still resolves its notebook relation (remapped id).
    final copiedInNb = bNotes
        .firstWhere((r) => r.getStringValue('title') == 'A note in notebook');
    expect(copiedInNb.getStringValue('notebook'), isNotEmpty,
        reason: 'notebook relation should be remapped to the new notebook id');
    expect(copiedInNb.getStringValue('notebook'),
        bNbs.firstWhere((r) => r.getStringValue('name') == 'Work').id);

    // Account A is untouched — its originals stay (merge is non-destructive).
    final aNotes =
        await pbA.collection('notes').getFullList(filter: 'deleted = false');
    expect(aNotes.length, 3, reason: "A's originals are not moved or deleted");

    await db.close();
  });
}
