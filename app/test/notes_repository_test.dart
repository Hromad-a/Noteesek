import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/data/notes_repository.dart';
import 'package:noteesek/features/import/import_models.dart';
import 'package:noteesek/features/import/import_service.dart';

void main() {
  late AppDatabase db;
  late NotesRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LocalNotesRepository(db, 'owner1');
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

  test('import service writes notes/items and find-or-creates labels',
      () async {
    final svc = NoteImportService(repo);
    final result = await svc.import([
      const ParsedNote(
        type: 'checklist',
        title: 'Trip',
        labelNames: ['Travel'],
        notebookName: 'Trips',
        items: [ImportedItem('passport', true), ImportedItem('tickets', false)],
      ),
      const ParsedNote(
        type: 'text',
        title: 'Note',
        body: 'hello',
        labelNames: ['Travel'], // same label → reused, not duplicated
        originalCreated: '2024-01-02 00:00:00.000Z',
      ),
    ]);

    expect(result.imported, 2);

    final labels = await repo.watchLabels().first;
    expect(labels.where((l) => l.name == 'Travel').length, 1);

    final notebooks = await repo.watchNotebooks().first;
    expect(notebooks.where((n) => n.name == 'Trips').length, 1);

    final notes = await repo.watchActive().first;
    final checklist = notes.firstWhere((n) => n.title == 'Trip');
    final items = await repo.watchItems(checklist.id).first;
    expect(items.map((i) => i.content).toList(), ['passport', 'tickets']);
    expect(items.first.checked, isTrue);

    // The original creation date is preserved in the body as a footnote.
    final text = notes.firstWhere((n) => n.title == 'Note');
    expect(text.body, contains('hello'));
    expect(text.body, contains('2024-01-02'));
  });

  test('hasForeignLocalData: ignores own data + a lone offline default', () async {
    // Only this account's data → no foreign data.
    await repo.ensureDefaultNotebook();
    await repo.createNote(type: 'text');
    expect(await repo.hasForeignLocalData('owner1'), isFalse);

    // A lone offline default notebook (different owner) doesn't count…
    final repoLocal = LocalNotesRepository(db, 'local');
    await repoLocal.ensureDefaultNotebook();
    expect(await repo.hasForeignLocalData('owner1'), isFalse);

    // …but a foreign note does.
    await repoLocal.createNote(type: 'text');
    expect(await repo.hasForeignLocalData('owner1'), isTrue);
  });

  test('reownAll re-owns every local row (any owner) to the user', () async {
    final repoLocal = LocalNotesRepository(db, 'local');
    await repoLocal.createNote(type: 'text'); // owner='local'
    await repoLocal.createNotebook('Offline');
    final repoOther = LocalNotesRepository(db, 'accountX');
    await repoOther.createNote(type: 'text'); // owner='accountX'

    expect(await repo.hasForeignLocalData('owner1'), isTrue);
    await repo.reownAll('owner1');
    expect(await repo.hasForeignLocalData('owner1'), isFalse);

    final notes = await db.select(db.notes).get();
    expect(notes, isNotEmpty);
    expect(notes.every((n) => n.owner == 'owner1' && n.dirty), isTrue);
    final nbs = await db.select(db.notebooks).get();
    expect(nbs.every((n) => n.owner == 'owner1' && n.dirty), isTrue);
  });

  test('combineNotebooksByName merges same-name notebooks + moves notes',
      () async {
    final a = await repo.createNotebook('Work'); // earliest → keeper
    final b = await repo.createNotebook('Work');
    final keep = await repo.createNotebook('Personal'); // unique → untouched
    final na = await repo.createNote(type: 'text', notebook: a);
    final nb = await repo.createNote(type: 'text', notebook: b);

    await repo.combineNotebooksByName();

    final nbs = await repo.watchNotebooks().first;
    expect(nbs.where((n) => n.name == 'Work').map((n) => n.id), [a],
        reason: 'the two Work notebooks collapse to the earliest');
    expect(nbs.where((n) => n.name == 'Personal').map((n) => n.id), [keep]);

    final notes = await db.select(db.notes).get();
    expect(notes.firstWhere((n) => n.id == na).notebook, a);
    expect(notes.firstWhere((n) => n.id == nb).notebook, a,
        reason: "the duplicate's note is moved to the keeper");
  });

  test('reorderItems reassigns positions to the given order', () async {
    final id = await repo.createNote(type: 'checklist');
    final a = await repo.addItem(id, content: 'a');
    final b = await repo.addItem(id, content: 'b');
    final c = await repo.addItem(id, content: 'c');

    // watchItems is ordered by position; initial order is a, b, c.
    expect((await repo.watchItems(id).first).map((i) => i.id).toList(),
        [a, b, c]);

    await repo.reorderItems([c, a, b]);
    final items = await repo.watchItems(id).first;
    expect(items.map((i) => i.id).toList(), [c, a, b]);
    expect(items.map((i) => i.position).toList(), [0, 1, 2]);
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
    final localRepo = LocalNotesRepository(db, 'local');
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
    await repo.deleteForever(id);
    expect((await repo.watchTrash().first), isEmpty);
    // Children removed too.
    expect(await repo.watchItems(id).first, isEmpty);
  });

  group('notebooks', () {
    test('ensureDefaultNotebook creates one default named "Notebook"',
        () async {
      final id = await repo.ensureDefaultNotebook();
      final notebooks = await repo.watchNotebooks().first;
      expect(notebooks, hasLength(1));
      expect(notebooks.single.id, id);
      expect(notebooks.single.name, 'Notebook');
      expect(notebooks.single.isDefault, isTrue);

      // Idempotent: a second call returns the same id, no duplicate created.
      expect(await repo.ensureDefaultNotebook(), id);
      expect(await repo.watchNotebooks().first, hasLength(1));
    });

    test('ensureDefaultNotebook reconciles duplicate defaults to the earliest',
        () async {
      final first = await repo.ensureDefaultNotebook();
      // Simulate a second default arriving (e.g. pulled from the server) by
      // forcing another default row in directly.
      final second = await repo.createNotebook('Other');
      await (db.update(db.notebooks)..where((t) => t.id.equals(second)))
          .write(const NotebooksCompanion(isDefault: Value(true)));

      final kept = await repo.ensureDefaultNotebook();
      expect(kept, first, reason: 'earliest-created default wins');
      final live = await repo.watchNotebooks().first;
      expect(live.map((n) => n.id), isNot(contains(second)));
    });

    test('createNote stamps the notebook', () async {
      final nb = await repo.createNotebook('Work');
      final id = await repo.createNote(type: 'text', notebook: nb);
      final note = await (db.select(db.notes)..where((t) => t.id.equals(id)))
          .getSingle();
      expect(note.notebook, nb);
    });

    test('deleteNotebook moves notes to the default', () async {
      final defaultId = await repo.ensureDefaultNotebook();
      final nb = await repo.createNotebook('Work');
      final id = await repo.createNote(type: 'text', notebook: nb);

      await repo.deleteNotebook(nb, moveNotesToDefault: true);

      final note = await (db.select(db.notes)..where((t) => t.id.equals(id)))
          .getSingle();
      expect(note.notebook, defaultId);
      expect(note.deleted, isFalse);
      expect((await repo.watchNotebooks().first).map((n) => n.id),
          isNot(contains(nb)));
    });

    test('deleteNotebook can trash its notes instead', () async {
      final nb = await repo.createNotebook('Work');
      final id = await repo.createNote(type: 'text', notebook: nb);

      await repo.deleteNotebook(nb, moveNotesToDefault: false);

      final note = await (db.select(db.notes)..where((t) => t.id.equals(id)))
          .getSingle();
      expect(note.deleted, isTrue);
    });

    test('the default notebook cannot be deleted', () async {
      final defaultId = await repo.ensureDefaultNotebook();
      await repo.deleteNotebook(defaultId, moveNotesToDefault: false);
      expect((await repo.watchNotebooks().first).map((n) => n.id),
          contains(defaultId));
    });
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
