@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/notes_repository.dart';
import 'package:noteesek/sync/sync_engine.dart';

// Requires the PocketBase backend running at this URL (server/docker compose up).
const baseUrl = 'http://localhost:8090';

void main() {
  late PocketBase pb;
  late String userId;

  setUpAll(() async {
    pb = PocketBase(baseUrl);
    final email = 'sync_${DateTime.now().microsecondsSinceEpoch}@example.com';
    await pb.collection('users').create(body: {
      'email': email,
      'password': 'password123',
      'passwordConfirm': 'password123',
    });
    await pb.collection('users').authWithPassword(email, 'password123');
    userId = pb.authStore.record!.id;
  });

  test('push then pull round-trips a note + checklist to a 2nd device',
      () async {
    // Device A: create a text note and a checklist with one item.
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = NotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);

    final noteId = await repoA.createNote(type: 'text');
    await repoA.updateNoteFields(noteId, title: 'Hello sync', body: 'b');
    final clId = await repoA.createNote(type: 'checklist');
    final itemId = await repoA.addItem(clId, content: 'Buy milk');

    expect(await engineA.syncOnce(), isTrue);

    // It now exists server-side.
    final rec = await pb.collection('notes').getOne(noteId);
    expect(rec.getStringValue('title'), 'Hello sync');

    // Device B: fresh local DB, same account → pull.
    final dbB = AppDatabase(NativeDatabase.memory());
    final engineB = SyncEngine(dbB, pb);
    final repoB = NotesRepository(dbB, userId);
    await engineB.syncOnce();

    final notesB = await repoB.watchActive().first;
    expect(notesB.map((n) => n.id), containsAll([noteId, clId]));
    expect(notesB.firstWhere((n) => n.id == noteId).title, 'Hello sync');
    final itemsB = await repoB.watchItems(clId).first;
    expect(itemsB.single.id, itemId);
    expect(itemsB.single.content, 'Buy milk');

    await dbA.close();
    await dbB.close();
  });

  test('server change overwrites a clean local copy on pull', () async {
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = NotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);
    final id = await repoA.createNote(type: 'text');
    await repoA.updateNoteFields(id, title: 'v1');
    await engineA.syncOnce();

    // Device B pulls v1 (clean copy).
    final dbB = AppDatabase(NativeDatabase.memory());
    final repoB = NotesRepository(dbB, userId);
    final engineB = SyncEngine(dbB, pb);
    await engineB.syncOnce();
    expect((await repoB.watchNote(id).first)!.title, 'v1');

    // A edits to v2 and syncs.
    await repoA.updateNoteFields(id, title: 'v2');
    await engineA.syncOnce();

    // B pulls again → clean local is overwritten with v2.
    await engineB.syncOnce();
    expect((await repoB.watchNote(id).first)!.title, 'v2');

    await dbA.close();
    await dbB.close();
  });

  test('image attachment uploads then downloads to a 2nd device', () async {
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = NotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);

    final noteId = await repoA.createNote(type: 'text');
    await repoA.updateNoteFields(noteId, title: 'with image');
    final bytes = Uint8List.fromList(List.generate(512, (i) => i % 256));
    final attId = await repoA.addAttachment(noteId, bytes);

    await engineA.syncOnce();

    // Server now has the file; local A row records the filename and is clean.
    final rec = await pb.collection('attachments').getOne(attId);
    expect(rec.getStringValue('file'), isNotEmpty);
    final aRow = await (dbA.select(dbA.attachments)
          ..where((t) => t.id.equals(attId)))
        .getSingle();
    expect(aRow.file, isNotEmpty);
    expect(aRow.dirty, isFalse);

    // Device B pulls and downloads the bytes.
    final dbB = AppDatabase(NativeDatabase.memory());
    final engineB = SyncEngine(dbB, pb);
    await engineB.syncOnce();

    final bRow = await (dbB.select(dbB.attachments)
          ..where((t) => t.id.equals(attId)))
        .getSingle();
    expect(bRow.note, noteId);
    expect(bRow.data, isNotNull);
    expect(bRow.data, equals(bytes));

    await dbA.close();
    await dbB.close();
  });

  test('soft delete propagates to the other device', () async {
    final dbA = AppDatabase(NativeDatabase.memory());
    final repoA = NotesRepository(dbA, userId);
    final engineA = SyncEngine(dbA, pb);
    final id = await repoA.createNote(type: 'text');
    await repoA.updateNoteFields(id, title: 'to delete');
    await engineA.syncOnce();

    final dbB = AppDatabase(NativeDatabase.memory());
    final repoB = NotesRepository(dbB, userId);
    final engineB = SyncEngine(dbB, pb);
    await engineB.syncOnce();
    expect((await repoB.watchActive().first).map((n) => n.id), contains(id));

    // Delete on A, sync, then B pulls.
    await repoA.softDelete(id);
    await engineA.syncOnce();
    await engineB.syncOnce();

    expect((await repoB.watchActive().first).map((n) => n.id),
        isNot(contains(id)));

    await dbA.close();
    await dbB.close();
  });
}
