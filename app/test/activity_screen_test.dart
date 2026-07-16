import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';

import 'package:noteesek/features/activity/activity_screen.dart';
import 'package:noteesek/features/activity/activity_service.dart';
import 'package:noteesek/l10n/l10n.dart';

/// A service that records calls but never touches the network, so the screen's
/// mark-all-read on open and the per-row archive buttons are exercised safely.
class _FakeActivityService extends ActivityService {
  _FakeActivityService() : super(PocketBase('http://localhost'));
  int markAllReadCalls = 0;
  final List<String> archived = [];
  @override
  Future<void> markAllRead() async => markAllReadCalls++;
  @override
  Future<void> archive(String id) async => archived.add(id);
  @override
  Future<void> unarchive(String id) async => archived.remove(id);
}

void main() {
  String pbNowMinus(Duration d) {
    final n = DateTime.now().toUtc().subtract(d);
    String p2(int v) => v.toString().padLeft(2, '0');
    String p3(int v) => v.toString().padLeft(3, '0');
    return '${n.year}-${p2(n.month)}-${p2(n.day)} '
        '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}.${p3(n.millisecond)}Z';
  }

  ActivityEntry entry(String id, Duration ago,
          {String action = 'edited', String title = 'Groceries'}) =>
      ActivityEntry(
        id: id,
        notebook: 'nb1',
        note: 'note_$id',
        actorEmail: 'jana@example.com',
        action: action,
        noteTitle: title,
        created: pbNowMinus(ago),
      );

  Future<_FakeActivityService> pumpScreen(
    WidgetTester tester, {
    required List<ActivityEntry> entries,
    Set<String> archivedIds = const {},
  }) async {
    final fake = _FakeActivityService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activityServiceProvider.overrideWithValue(fake),
          activityEntriesProvider.overrideWith((ref) => Stream.value(entries)),
          activitySeenAtProvider.overrideWith((ref) => Stream.value(null)),
          activityArchivedIdsProvider
              .overrideWith((ref) => Stream.value(archivedIds)),
        ],
        child: MaterialApp(
          supportedLocales: kSupportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const ActivityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fake;
  }

  testWidgets('renders inbox entries and marks all read on open',
      (tester) async {
    final fake = await pumpScreen(tester, entries: [
      entry('a', const Duration(hours: 1)),
      entry('b', const Duration(days: 2)),
    ]);

    // Both recent entries show in the inbox, with the actor and note title.
    expect(find.text('jana@example.com'), findsNWidgets(2));
    expect(find.textContaining('Groceries'), findsNWidgets(2));
    // Opening the feed marks it read.
    expect(fake.markAllReadCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('old entries appear under the Archive tab, not the inbox',
      (tester) async {
    await pumpScreen(tester, entries: [
      entry('fresh', const Duration(hours: 1), title: 'Fresh'),
      entry('old', const Duration(days: 9), title: 'Ancient'),
    ]);

    // Inbox shows only the fresh one.
    expect(find.textContaining('Fresh'), findsOneWidget);
    expect(find.textContaining('Ancient'), findsNothing);

    // Switch to the Archive tab (localized "Archive").
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ancient'), findsOneWidget);
  });

  testWidgets('the archive button archives an inbox entry', (tester) async {
    final fake = await pumpScreen(tester, entries: [
      entry('a', const Duration(hours: 1)),
    ]);

    await tester.tap(find.byIcon(Icons.archive_outlined));
    await tester.pump();
    expect(fake.archived, ['a']);
  });
}
