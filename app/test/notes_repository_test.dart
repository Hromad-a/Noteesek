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
