import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/backup/backup_service.dart';
import 'package:noteesek/features/backup/v2/backup_preview.dart';
import 'package:noteesek/features/backup/v2/backup_v2.dart';

Future<BackupV2Reader> _reader() async {
  final db = AppDatabase(NativeDatabase.memory());
  final repo = LocalNotesRepository(db, 'a');
  final work = await repo.createNotebook('Work');
  final trips = await repo.createNotebook('Trips');
  final r1 = await repo.createNote(type: 'text', notebook: work);
  await repo.updateNoteFields(r1, title: 'Report', body: 'quarterly numbers');
  await repo.addAttachment(r1, Uint8List.fromList([1, 2]));
  final t1 = await repo.createNote(type: 'text', notebook: trips);
  await repo.updateNoteFields(t1, title: 'Lisbon');
  final loose = await repo.createNote(type: 'text'); // no notebook
  await repo.updateNoteFields(loose, title: 'Idea');
  final trashed = await repo.createNote(type: 'text', notebook: work);
  await repo.updateNoteFields(trashed, title: 'Old');
  await repo.softDelete(trashed); // → excluded from preview
  final bytes = await BackupService(db).exportV2();
  await db.close();
  return BackupV2Reader.read(bytes);
}

void main() {
  test('groups notes by notebook with a "No notebook" bucket last', () async {
    final data = buildBackupPreview(await _reader());
    expect(data.groups.map((g) => g.name), ['Trips', 'Work', 'No notebook']);
    expect(data.noteCount, 3, reason: 'trashed note excluded');
    expect(data.imageCount, 1);
    expect(data.healthy, isTrue);
    final work = data.groups.firstWhere((g) => g.name == 'Work');
    expect(work.notes.map((n) => n.title), ['Report']);
  });

  test('search filters notes and drops empty groups', () async {
    final data = buildBackupPreview(await _reader());
    final filtered = filterGroups(data.groups, 'lisbon');
    expect(filtered.map((g) => g.name), ['Trips']);
    expect(filtered.single.notes.single.title, 'Lisbon');
  });

  test('group tri-state reflects the selection', () async {
    final data = buildBackupPreview(await _reader());
    final work = data.groups.firstWhere((g) => g.name == 'Work');
    expect(groupState(work, {}), TriState.none);
    expect(groupState(work, {work.notes.first.id}), TriState.all,
        reason: 'Work has one note → fully selected');
    expect(allNoteIds(data.groups).length, 3);
  });

  test('tri-state: none / some / all on a multi-note group', () {
    BackupNoteSummary note(String id) => BackupNoteSummary(
        id: id,
        title: id,
        snippet: '',
        type: 'text',
        notebookId: 'x',
        thumb: null,
        damaged: false);
    final g = BackupNotebookGroup(
        notebookId: 'x', name: 'X', notes: [note('1'), note('2')]);
    expect(groupState(g, {}), TriState.none);
    expect(groupState(g, {'1'}), TriState.some);
    expect(groupState(g, {'1', '2'}), TriState.all);
  });
}
