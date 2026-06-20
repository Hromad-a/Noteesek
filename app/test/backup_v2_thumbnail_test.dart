import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/backup/backup_service.dart';
import 'package:noteesek/features/backup/v2/backup_preview.dart';
import 'package:noteesek/features/backup/v2/backup_v2.dart';

void main() {
  test('export generates a preview thumbnail for a real image', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(db, 'a');
    final n = await repo.createNote(type: 'text');
    await repo.updateNoteFields(n, title: 'Photo');

    final src = im.Image(width: 600, height: 400);
    im.fill(src, color: im.ColorRgb8(120, 80, 200));
    final png = Uint8List.fromList(im.encodePng(src));
    await repo.addAttachment(n, png);

    final bytes = await BackupService(db).exportV2();
    final archive = ZipDecoder().decodeBytes(bytes);

    final thumbs =
        archive.files.where((f) => f.name.startsWith('thumbs/')).toList();
    expect(thumbs.length, 1);
    expect(thumbs.single.name, matches(r'^thumbs/[0-9a-f]{64}\.jpg$'),
        reason: 'thumbnail is keyed by the image content hash');
    expect(thumbs.single.size, greaterThan(0));

    // The preview surfaces the thumb ref so the grid can render it.
    final preview = buildBackupPreview(BackupV2Reader.read(bytes));
    final note = preview.groups.expand((g) => g.notes).first;
    expect(note.thumb, isNotNull);
    expect(note.thumb, thumbs.single.name);

    await db.close();
  });
}
