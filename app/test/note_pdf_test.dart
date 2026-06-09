import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/export/note_pdf.dart';
import 'package:noteesek/features/export/pdf_fonts.dart';

void main() {
  // rootBundle (used to load the bundled fonts) needs the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late LocalNotesRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = LocalNotesRepository(db, 'owner1');
  });

  tearDown(() => db.close());

  test('bundled fonts load from assets', () async {
    final fonts = await PdfFonts.load();
    expect(fonts.base, isNotNull);
    expect(fonts.mono, isNotNull);
  });

  test('renders a markdown text note (incl. Czech) to a valid PDF', () async {
    final id = await repo.createNote(type: 'text');
    await repo.updateNoteFields(id,
        title: 'Příliš žluťoučký kůň',
        body:
            '# Nadpis\n\nPříliš **žluťoučký** kůň úpěl *ďábelské* ódy.\n\n- jedna\n- dvě');
    final note = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingle();

    final bytes = await buildNotePdf(note: note, items: const [], attachments: const []);
    expect(bytes.lengthInBytes, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('renders a checklist note to a valid PDF', () async {
    final id = await repo.createNote(type: 'checklist');
    final a = await repo.addItem(id, content: 'koupit mléko');
    await repo.setItemChecked(a, true);
    await repo.addItem(id, content: 'zavolat lékaři');
    final note = await (db.select(db.notes)..where((t) => t.id.equals(id)))
        .getSingle();
    final items = await repo.watchItems(id).first;

    final bytes = await buildNotePdf(note: note, items: items, attachments: const []);
    expect(bytes.lengthInBytes, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
