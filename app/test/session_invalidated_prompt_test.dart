import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:noteesek/app.dart';
import 'package:noteesek/config/app_config.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/providers.dart';

/// When a session is invalidated server-side (a 401 rejected a token we held —
/// e.g. the password was changed), the app shows a one-time "you've been signed
/// out" prompt on open, with a button to sign in again. The flag is persisted,
/// so a value of true in SharedPreferences at launch reproduces it.
void main() {
  testWidgets('shows the signed-out prompt when the session was invalidated',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      AppConfig.kSeenOnboarding: true, // skip first-run intro
      AppConfig.kSessionInvalidated: true, // a session was invalidated
    });
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

    // The prompt is up, titled and explained, with a sign-in action.
    expect(find.text('Signed out'), findsOneWidget);
    expect(
      find.textContaining('signed out', findRichText: true),
      findsWidgets,
    );
    final signIn = find.widgetWithText(TextButton, 'Sign in');
    expect(signIn, findsOneWidget);

    // Acknowledging clears the persisted flag so it won't nag next launch.
    await tester.tap(signIn);
    await tester.pumpAndSettle();
    expect(prefs.getBool(AppConfig.kSessionInvalidated), isNull);
    expect(find.text('Signed out'), findsNothing);

    // Dispose so drift's stream-cleanup timer fires before the pending-timer check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('no prompt when the session was never invalidated',
      (tester) async {
    SharedPreferences.setMockInitialValues({AppConfig.kSeenOnboarding: true});
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

    expect(find.text('Signed out'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
