import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/backup/backup_service.dart';
import 'package:noteesek/features/backup/v2/backup_v2.dart';
import 'package:noteesek/features/backup/v2/backup_v2_import.dart';

void main() {
  // Build a backup from account A, then "add as copies" into account B.
  Future<Uint8List> sampleBackup() async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'acctA');
    final work = await repo.createNotebook('Work');
    final trips = await repo.createNotebook('Trips');
    final label = await repo.createLabel('urgent');
    final n1 = await repo.createNote(type: 'text', notebook: work);
    await repo.updateNoteFields(n1, title: 'Report', body: 'draft');
    await repo.setNoteLabels(n1, [label]);
    await repo.addAttachment(n1, Uint8List.fromList([9, 9, 9]));
    final n2 = await repo.createNote(type: 'text', notebook: trips);
    await repo.updateNoteFields(n2, title: 'Lisbon');
    final bytes = await BackupService(db).exportV2();
    await db.close();
    return bytes;
  }

  test('add-as-copies brings notes in with new ids + current owner', () async {
    final backup = await sampleBackup();
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'acctB');

    final added = await addNotesFromBackup(repo, BackupV2Reader.read(backup));
    expect(added, 2);

    final notes = await db.select(db.notes).get();
    expect(notes.map((n) => n.title), containsAll(['Report', 'Lisbon']));
    expect(notes.every((n) => n.owner == 'acctB'), isTrue,
        reason: 'copies are owned by the importing account');
    // Labels + notebooks were re-created by name in the target account.
    expect((await repo.watchNotebooks().first).map((n) => n.name),
        containsAll(['Work', 'Trips']));
    expect((await repo.watchLabels().first).map((l) => l.name), contains('urgent'));
    // The image came across.
    final report = notes.firstWhere((n) => n.title == 'Report');
    expect((await repo.watchAttachments(report.id).first).single.data,
        Uint8List.fromList([9, 9, 9]));

    await db.close();
  });

  test('selective add imports only the chosen notes', () async {
    final backup = await sampleBackup();
    final r = BackupV2Reader.read(backup);
    final lisbonId =
        r.notes.firstWhere((n) => n['title'] == 'Lisbon')['id'] as String;

    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'acctB');
    final added =
        await addNotesFromBackup(repo, r, selectedNoteIds: {lisbonId});
    expect(added, 1);
    expect((await db.select(db.notes).get()).single.title, 'Lisbon');
    await db.close();
  });

  test('targetNotebookName overrides the destination notebook', () async {
    final backup = await sampleBackup();
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'acctB');

    await addNotesFromBackup(repo, BackupV2Reader.read(backup),
        targetNotebookName: 'Imported');

    final nbs = await repo.watchNotebooks().first;
    expect(nbs.map((n) => n.name), contains('Imported'));
    expect(nbs.map((n) => n.name), isNot(contains('Work')),
        reason: 'all notes were redirected into the one target notebook');
    await db.close();
  });
}
