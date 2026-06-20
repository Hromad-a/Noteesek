import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/local_notes_repository.dart';
import 'package:noteesek/features/backup/backup_service.dart';
import 'package:noteesek/features/backup/v2/backup_restore_screen.dart';
import 'package:noteesek/providers.dart';

void main() {
  testWidgets('renders a backup grouped by notebook with restore actions',
      (tester) async {
    // Build a backup (no images → no async thumbnail decode in the test).
    final src = AppDatabase(NativeDatabase.memory());
    final repo = LocalNotesRepository(src, 'a');
    final work = await repo.createNotebook('Work');
    final trips = await repo.createNotebook('Trips');
    final n1 = await repo.createNote(type: 'text', notebook: work);
    await repo.updateNoteFields(n1, title: 'Report');
    final n2 = await repo.createNote(type: 'text', notebook: trips);
    await repo.updateNoteFields(n2, title: 'Lisbon');
    final n3 = await repo.createNote(type: 'text');
    await repo.updateNoteFields(n3, title: 'Idea');
    final Uint8List bytes = await BackupService(src).exportV2();
    await src.close();

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
        ],
        child: MaterialApp(
          home: BackupRestoreScreen(bytes: bytes, sourceLabel: 'test.zip'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Grouped by notebook, health verified, default = all selected.
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('No notebook'), findsOneWidget);
    expect(find.text('verified'), findsOneWidget);
    // Backup file (default) → by-id restore actions, not copy actions.
    expect(find.text('Restore 3 selected'), findsOneWidget);
    expect(find.text('Replace all…'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
