import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/features/backup/snapshot_service.dart';

void main() {
  group('SnapshotContents.parse', () {
    List<int> bytesOf(Map<String, dynamic> json) => utf8.encode(jsonEncode(json));

    test('parses notes, skips deleted, groups items + image counts', () {
      final bytes = bytesOf({
        'format': 1,
        'notes': [
          {'id': 'n1', 'type': 'text', 'title': 'Hello', 'body': 'world',
            'labels': '["l1"]', 'deleted': false},
          {'id': 'n2', 'type': 'checklist', 'title': '', 'body': '',
            'labels': '[]', 'deleted': false},
          {'id': 'n3', 'type': 'text', 'title': 'Gone', 'body': '',
            'labels': '[]', 'deleted': true}, // excluded
        ],
        'checklistItems': [
          {'id': 'i1', 'note': 'n2', 'content': 'milk', 'checked': false},
          {'id': 'i2', 'note': 'n2', 'content': 'eggs', 'checked': true},
          {'id': 'i3', 'note': 'n2', 'content': 'old', 'checked': false,
            'deleted': true}, // excluded
        ],
        'attachments': [
          {'id': 'a1', 'note': 'n1', 'file': 'x.jpg', 'deleted': false},
          {'id': 'a2', 'note': 'n1', 'file': 'y.jpg', 'deleted': false},
          {'id': 'a3', 'note': 'n1', 'file': 'z.jpg', 'deleted': true},
        ],
      });

      final c = SnapshotContents.parse(bytes);

      expect(c.notes.map((n) => n.id), ['n1', 'n2']); // n3 (deleted) excluded
      final n1 = c.notes.firstWhere((n) => n.id == 'n1');
      expect(n1.labelIds, ['l1']);
      expect(n1.imageCount, 2); // a3 deleted not counted
      final n2 = c.notes.firstWhere((n) => n.id == 'n2');
      expect(n2.items.length, 2); // i3 deleted excluded
      expect(n2.items.map((e) => e.content), ['milk', 'eggs']);
      expect(n2.items[1].checked, isTrue);
    });

    test('displayTitle falls back to checklist item then body line', () {
      final bytes = bytesOf({
        'format': 1,
        'notes': [
          {'id': 'n1', 'type': 'text', 'title': '', 'body': 'first line\nsecond',
            'labels': '[]', 'deleted': false},
          {'id': 'n2', 'type': 'checklist', 'title': '', 'body': '',
            'labels': '[]', 'deleted': false},
        ],
        'checklistItems': [
          {'id': 'i1', 'note': 'n2', 'content': 'buy milk', 'checked': false},
        ],
        'attachments': [],
      });

      final c = SnapshotContents.parse(bytes);
      expect(c.notes.firstWhere((n) => n.id == 'n1').displayTitle, 'first line');
      expect(c.notes.firstWhere((n) => n.id == 'n2').displayTitle, 'buy milk');
    });

    test('rejects a non-object payload', () {
      expect(() => SnapshotContents.parse(utf8.encode('[]')),
          throwsA(isA<FormatException>()));
    });
  });
}
