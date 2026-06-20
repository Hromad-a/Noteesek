import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/backup/backup_service.dart';
import 'package:noteesek/features/backup/v2/backup_preview.dart';
import 'package:noteesek/features/backup/v2/backup_v2.dart';

void main() {
  test('v2 BackupService: export → wipe → import round-trips everything',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'owner1');

    final nb = await repo.createNotebook('Trip');
    final n = await repo.createNote(type: 'text', notebook: nb);
    await repo.updateNoteFields(n, title: 'Packing', body: 'socks & passport');
    final labelId = await repo.createLabel('travel');
    await repo.setNoteLabels(n, [labelId]);
    final imageBytes = Uint8List.fromList([4, 8, 15, 16, 23, 42]);
    await repo.addAttachment(n, imageBytes);
    final cl = await repo.createNote(type: 'checklist');
    await repo.addItem(cl, content: 'passport');

    final svc = BackupService(db);
    final backup = await svc.exportV2();

    await db.wipeAllLocal();
    expect(await repo.watchActive().first, isEmpty);

    final restored = await svc.importV2(backup, 'owner1');
    expect(restored, 2, reason: 'the text note + the checklist');

    final active = await repo.watchActive().first;
    expect(active.map((x) => x.title), contains('Packing'));
    expect((await repo.watchNotebooks().first).map((x) => x.name),
        contains('Trip'));
    expect((await repo.watchLabels().first).map((x) => x.name),
        contains('travel'));
    expect((await repo.watchItems(cl).first).single.content, 'passport');
    expect((await repo.watchAttachments(n).first).single.data, imageBytes,
        reason: 'attachment bytes restored from the content-addressed blob');

    // The restored note keeps its label + notebook relations (by id).
    final packing = active.firstWhere((x) => x.title == 'Packing');
    expect(packing.notebook, nb);
    expect(packing.owner, 'owner1');

    await db.close();
  });

  test('importV2 with a foreign owner re-stamps all rows', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'acctA');
    final n = await repo.createNote(type: 'text');
    await repo.updateNoteFields(n, title: 'hi');

    final backup = await BackupService(db).exportV2();
    await db.wipeAllLocal();
    await BackupService(db).importV2(backup, 'acctB');

    final all = await db.select(db.notes).get();
    expect(all.single.owner, 'acctB', reason: 'owner is stamped on import');

    await db.close();
  });

  test('importV2 selectedNoteIds restores in place by id — no duplicates',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'u');
    final n1 = await repo.createNote(type: 'text');
    await repo.updateNoteFields(n1, title: 'A');
    final n2 = await repo.createNote(type: 'text');
    await repo.updateNoteFields(n2, title: 'B');
    final backup = await BackupService(db).exportV2();

    await repo.updateNoteFields(n1, title: 'A-edited'); // diverge locally
    final restored =
        await BackupService(db).importV2(backup, 'u', selectedNoteIds: {n1});

    expect(restored, 1);
    final notes = await db.select(db.notes).get();
    expect(notes.length, 2, reason: 'restored in place — no new note');
    expect(notes.firstWhere((n) => n.id == n1).title, 'A',
        reason: 'A reverted to the backup version');
    expect(notes.firstWhere((n) => n.id == n2).title, 'B',
        reason: 'unselected note untouched');
    await db.close();
  });

  test('importV2 mirror trashes notes, notebooks and labels absent from backup',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'u');
    final keep = await repo.createNote(type: 'text');
    await repo.updateNoteFields(keep, title: 'keep');
    final keepNb = await repo.createNotebook('KeepBook');
    final keepLabel = await repo.createLabel('keepLabel');
    final backup = await BackupService(db).exportV2(); // the above only

    final extra = await repo.createNote(type: 'text'); // added after backup
    await repo.updateNoteFields(extra, title: 'extra');
    final extraNb = await repo.createNotebook('ExtraBook');
    final extraLabel = await repo.createLabel('extraLabel');

    await BackupService(db).importV2(backup, 'u', mirror: true);

    final notes = await db.select(db.notes).get();
    expect(notes.firstWhere((n) => n.id == keep).deleted, isFalse);
    expect(notes.firstWhere((n) => n.id == extra).deleted, isTrue);

    final nbs = await db.select(db.notebooks).get();
    expect(nbs.firstWhere((n) => n.id == keepNb).deleted, isFalse);
    expect(nbs.firstWhere((n) => n.id == extraNb).deleted, isTrue,
        reason: 'notebook absent from the backup → trashed');

    final labels = await db.select(db.labels).get();
    expect(labels.firstWhere((l) => l.id == keepLabel).deleted, isFalse);
    expect(labels.firstWhere((l) => l.id == extraLabel).deleted, isTrue,
        reason: 'label absent from the backup → trashed');
    await db.close();
  });

  test('exported empty notebook still appears in the restore preview',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'u');
    await repo.createNotebook('Empty'); // no notes assigned
    final backup = await BackupService(db).exportV2();
    await db.close();

    final groups = buildBackupPreview(BackupV2Reader.read(backup)).groups;
    final empty = groups.firstWhere((g) => g.name == 'Empty');
    expect(empty.notes, isEmpty, reason: 'visible despite holding no notes');
  });
}
