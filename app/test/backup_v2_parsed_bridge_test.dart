import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/data/notes_repository.dart' show ImportedItem;
import 'package:noteesek/features/backup/v2/backup_preview.dart';
import 'package:noteesek/features/backup/v2/backup_v2.dart';
import 'package:noteesek/features/backup/v2/backup_v2_import.dart';
import 'package:noteesek/features/import/import_models.dart';

void main() {
  final notes = [
    const ParsedNote(
        type: 'text',
        title: 'Alpha',
        body: 'hello',
        notebookName: 'Work',
        labelNames: ['urgent']),
    const ParsedNote(
        type: 'checklist',
        title: 'Beta',
        notebookName: 'Trips',
        items: [ImportedItem('pack', false)]),
    const ParsedNote(type: 'text', title: 'Gamma'),
  ];

  test('parsed notes pack into a v2 package and preview by notebook', () async {
    final reader = BackupV2Reader.read(await parsedNotesToBackupBytes(notes));
    final data = buildBackupPreview(reader);
    expect(data.groups.map((g) => g.name),
        containsAll(['Work', 'Trips', 'No notebook']));
    expect(data.noteCount, 3);
  });

  test('the packaged notes import as copies via the shared add path', () async {
    final reader = BackupV2Reader.read(await parsedNotesToBackupBytes(notes));
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'me');

    final added = await addNotesFromBackup(repo, reader);
    expect(added, 3);
    expect((await repo.watchNotebooks().first).map((n) => n.name),
        containsAll(['Work', 'Trips']));
    expect((await repo.watchLabels().first).map((l) => l.name), contains('urgent'));

    await db.close();
  });
}
