import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:noteesek/app.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/providers.dart';

void main() {
  testWidgets('opens directly to local notes (no login gate)', (tester) async {
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
        child: const NoteesekApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Lands on the notes screen in local-only mode — no login required.
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('Notes you add appear here'), findsOneWidget);

    // Dispose the tree so provider subscriptions are cancelled, then advance
    // the clock so drift's stream-cleanup timer fires before the framework's
    // end-of-test "no pending timers" invariant check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
