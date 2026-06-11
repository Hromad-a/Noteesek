@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/backup/remote_backup_service.dart';
import 'package:noteesek/sync/sync_engine.dart';

const baseUrl = 'http://localhost:8090';

void main() {
  test('RemoteBackupService round-trips an account via the API (web backup)',
      () async {
    final pb = PocketBase(baseUrl);
    final email = 'rbk_${DateTime.now().microsecondsSinceEpoch}@example.com';
    await pb.collection('users').create(body: {
      'email': email,
      'password': 'password123',
      'passwordConfirm': 'password123',
    });
    await pb.collection('users').authWithPassword(email, 'password123');
    final userId = pb.authStore.record!.id;

    // Seed the account's server data via a local repo + sync.
    final seedDb = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(seedDb, userId);
    final engine = SyncEngine(seedDb, pb);
    final nb = await repo.createNotebook('Trip');
    final labelId = await repo.createLabel('travel');
    final note = await repo.createNote(type: 'text', notebook: nb);
    await repo.updateNoteFields(note, title: 'Packing', body: 'socks');
    await repo.setNoteLabels(note, [labelId]);
    final bytes = Uint8List.fromList([4, 8, 15, 16, 23, 42]);
    await repo.addAttachment(note, bytes);
    final cl = await repo.createNote(type: 'checklist');
    await repo.addItem(cl, content: 'passport');
    await engine.syncOnce();
    await seedDb.close();

    // Export the whole account through the API.
    final svc = RemoteBackupService(pb);
    final backup = await svc.export();

    // Wipe every record on the server (simulate a fresh/empty account).
    for (final col in const [
      'attachments',
      'checklist_items',
      'notes',
      'labels',
      'notebooks'
    ]) {
      for (final r in await pb.collection(col).getFullList()) {
        await pb.collection(col).delete(r.id);
      }
    }
    expect(
        (await pb.collection('notes').getFullList(filter: 'deleted = false'))
            .length,
        0);

    // Restore from the backup.
    final restored = await svc.import(backup);
    expect(restored, 2, reason: 'two notes in the backup');

    // Verify by pulling fresh into a new local DB.
    final db2 = AppDatabase(NativeDatabase.memory());
    final repo2 = LocalNotesRepository(db2, userId);
    final engine2 = SyncEngine(db2, pb);
    await engine2.syncOnce();

    expect((await repo2.watchNotebooks().first).map((n) => n.name),
        contains('Trip'));
    expect((await repo2.watchLabels().first).map((l) => l.name),
        contains('travel'));
    final active = await repo2.watchActive().first;
    expect(active.map((n) => n.title), containsAll(['Packing']));
    final packing = active.firstWhere((n) => n.title == 'Packing');
    expect(packing.notebook, isNotEmpty,
        reason: 'notebook relation restored');
    expect((await repo2.watchItems(cl).first).map((i) => i.content),
        contains('passport'));
    expect((await repo2.watchAttachments(note).first).single.data, bytes,
        reason: 'attachment bytes restored');

    await db2.close();
  });
}
