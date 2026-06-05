import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:noteesek/app.dart';
import 'package:noteesek/providers.dart';

void main() {
  testWidgets('shows login screen when not authenticated', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const NoteesekApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Noteesek'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
  });
}
