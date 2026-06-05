import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/notes_repository.dart';

void main() {
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = NotesRepository(db, 'owner1');
  });

  tearDown(() => db.close());

  test('create text note is active, dirty and owned', () async {
    final id = await repo.createNote(type: 'text');
    await repo.updateNoteFields(id, title: 'Groceries', body: 'eggs');

    final active = await repo.watchActive().first;
    expect(active, hasLength(1));
    final n = active.single;
    expect(n.id, id);
    expect(n.owner, 'owner1');
    expect(n.title, 'Groceries');
    expect(n.body, 'eggs');
    expect(n.dirty, isTrue);
    expect(n.updated, isNotEmpty);
  });

  test('checklist items add and check', () async {
    final id = await repo.createNote(type: 'checklist');
    final itemId = await repo.addItem(id, content: 'Buy milk');

    var items = await repo.watchItems(id).first;
    expect(items.single.content, 'Buy milk');
    expect(items.single.checked, isFalse);

    await repo.setItemChecked(itemId, true);
    items = await repo.watchItems(id).first;
    expect(items.single.checked, isTrue);

    await repo.deleteItem(itemId);
    items = await repo.watchItems(id).first;
    expect(items, isEmpty); // soft-deleted, filtered out
  });

  test('search matches title, body and checklist item content', () async {
    final a = await repo.createNote(type: 'text');
    await repo.updateNoteFields(a, title: 'Shopping', body: 'eggs and bread');
    final b = await repo.createNote(type: 'text');
    await repo.updateNoteFields(b, title: 'Ideas', body: 'paint the fence');
    final c = await repo.createNote(type: 'checklist');
    await repo.addItem(c, content: 'call the dentist');

    Future<Set<String>> search(String q) async =>
        (await repo.searchActive(q).first).map((n) => n.id).toSet();

    expect(await search('eggs'), {a}); // body match
    expect(await search('IDEAS'), {b}); // case-insensitive title match
    expect(await search('dentist'), {c}); // checklist item match
    expect(await search('the'), {b, c}); // body + item
    expect(await search('zzz'), isEmpty);
    expect(await search(''), {a, b, c}); // empty -> all active
  });

  test('claimLocalNotes reassigns local-owned notes to the account', () async {
    final localRepo = NotesRepository(db, 'local');
    final id = await localRepo.createNote(type: 'text');
    await localRepo.updateNoteFields(id, title: 'made offline');

    await localRepo.claimLocalNotes('user_123');

    final n = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingle();
    expect(n.owner, 'user_123');
    expect(n.dirty, isTrue);
  });

  test('trash: delete moves to trash, restore and purge work', () async {
    final id = await repo.createNote(type: 'checklist');
    await repo.updateNoteFields(id, title: 'temp');
    await repo.addItem(id, content: 'x');

    await repo.softDelete(id);
    expect((await repo.watchActive().first).map((n) => n.id), isNot(contains(id)));
    expect((await repo.watchTrash().first).map((n) => n.id), contains(id));

    await repo.restore(id);
    expect((await repo.watchTrash().first), isEmpty);
    expect((await repo.watchActive().first).map((n) => n.id), contains(id));

    await repo.softDelete(id);
    final purged = await repo.purgeLocal(id);
    expect(purged, contains(id));
    expect((await repo.watchTrash().first), isEmpty);
    // Children removed too.
    expect(await repo.watchItems(id).first, isEmpty);
  });

  test('pin sorts first; archive and delete leave the active list', () async {
    final a = await repo.createNote(type: 'text');
    await repo.updateNoteFields(a, title: 'A');
    final b = await repo.createNote(type: 'text');
    await repo.updateNoteFields(b, title: 'B');

    await repo.setPinned(b, true);
    var active = await repo.watchActive().first;
    expect(active.first.id, b, reason: 'pinned note sorts first');

    await repo.setArchived(a, true);
    active = await repo.watchActive().first;
    expect(active.map((n) => n.id), isNot(contains(a)));
    final archived = await repo.watchArchived().first;
    expect(archived.single.id, a);

    await repo.softDelete(b);
    active = await repo.watchActive().first;
    expect(active, isEmpty);
  });
}
