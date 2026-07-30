import 'package:flutter_test/flutter_test.dart';

import 'package:noteesek/features/activity/activity_service.dart';

/// The activity feed splits into a recent "inbox" and an "archive" (older than a
/// week OR manually archived), and the unread count is inbox entries newer than
/// the read watermark. This exercises that pure logic without any server.
void main() {
  // Fixed reference time so the age-based auto-archive is deterministic.
  final now = DateTime.utc(2026, 7, 16, 12, 0, 0);

  String pb(DateTime d) {
    String p2(int v) => v.toString().padLeft(2, '0');
    String p3(int v) => v.toString().padLeft(3, '0');
    final n = d.toUtc();
    return '${n.year}-${p2(n.month)}-${p2(n.day)} '
        '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}.${p3(n.millisecond)}Z';
  }

  ActivityEntry entry(String id, DateTime created, {String action = 'edited'}) =>
      ActivityEntry(
        id: id,
        notebook: 'nb1',
        note: 'note_$id',
        actorEmail: 'someone@example.com',
        action: action,
        noteTitle: 'A note',
        created: pb(created),
      );

  test('parsePbTime round-trips the pb format', () {
    final d = DateTime.utc(2026, 6, 5, 0, 14, 58, 581);
    expect(parsePbTime(pb(d)), d);
    expect(parsePbTime(''), isNull);
    expect(parsePbTime('not a date'), isNull);
  });

  test('recent, non-archived entries land in the inbox', () {
    final entries = [
      entry('a', now.subtract(const Duration(hours: 1))),
      entry('b', now.subtract(const Duration(days: 2))),
    ];
    final p = partitionActivity(entries, <String>{}, now);
    expect(p.inbox.map((e) => e.id), ['a', 'b']);
    expect(p.archive, isEmpty);
  });

  test('entries older than a week auto-archive', () {
    final entries = [
      entry('fresh', now.subtract(const Duration(days: 6))),
      entry('old', now.subtract(const Duration(days: 8))),
    ];
    final p = partitionActivity(entries, <String>{}, now);
    expect(p.inbox.map((e) => e.id), ['fresh']);
    expect(p.archive.map((e) => e.id), ['old']);
  });

  test('manual archive moves a recent entry to the archive', () {
    final entries = [
      entry('a', now.subtract(const Duration(hours: 1))),
      entry('b', now.subtract(const Duration(hours: 2))),
    ];
    final p = partitionActivity(entries, {'b'}, now);
    expect(p.inbox.map((e) => e.id), ['a']);
    expect(p.archive.map((e) => e.id), ['b']);
  });

  test('exactly one week old is archived (boundary)', () {
    final e = entry('x', now.subtract(kActivityAutoArchiveAfter));
    expect(activityIsArchived(e, <String>{}, now), isTrue);
  });

  test('unread counts inbox entries newer than the watermark', () {
    final inbox = [
      entry('a', now.subtract(const Duration(minutes: 5))),
      entry('b', now.subtract(const Duration(hours: 3))),
      entry('c', now.subtract(const Duration(hours: 10))),
    ];
    final seenAt = now.subtract(const Duration(hours: 4));
    // a and b are newer than the watermark; c is older.
    expect(unreadActivityCount(inbox, seenAt), 2);
  });

  test('everything is unread when never marked read', () {
    final inbox = [
      entry('a', now.subtract(const Duration(minutes: 5))),
      entry('b', now.subtract(const Duration(hours: 3))),
    ];
    expect(unreadActivityCount(inbox, null), 2);
  });

  test('nothing unread when the watermark is in the future', () {
    final inbox = [entry('a', now.subtract(const Duration(hours: 1)))];
    expect(unreadActivityCount(inbox, now.add(const Duration(hours: 1))), 0);
  });
}
