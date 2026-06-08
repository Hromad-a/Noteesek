import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/features/import/keep_import.dart';

Uint8List _zip(Map<String, Object> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    final bytes = content is String
        ? utf8.encode(content)
        : (content as Uint8List);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

void main() {
  test('parses active text + checklist notes, skips trashed', () {
    final zip = _zip({
      'Takeout/Keep/a.json': jsonEncode({
        'title': 'Hello',
        'textContent': 'world',
        'color': 'RED',
        'isPinned': true,
        'isArchived': false,
        'isTrashed': false,
        'labels': [
          {'name': 'Work'},
          {'name': 'Ideas'},
        ],
        'annotations': [
          {'url': 'https://x.com', 'title': 'X', 'source': 'WEBLINK'},
        ],
        'createdTimestampUsec': 1577923200000000, // 2020-01-02 (UTC)
      }),
      'Takeout/Keep/b.json': jsonEncode({
        'title': 'Groceries',
        'isArchived': true,
        'isTrashed': false,
        'listContent': [
          {'text': 'milk', 'isChecked': false},
          {'text': 'eggs', 'isChecked': true},
        ],
      }),
      'Takeout/Keep/gone.json': jsonEncode({
        'title': 'Old',
        'textContent': 'bye',
        'isTrashed': true,
      }),
    });

    final notes = parseKeepTakeout(zip);
    expect(notes.length, 2); // trashed skipped

    final text = notes.firstWhere((n) => n.title == 'Hello');
    expect(text.type, 'text');
    expect(text.color, 'coral'); // RED → coral
    expect(text.pinned, isTrue);
    expect(text.labelNames, ['Work', 'Ideas']);
    expect(text.body, contains('world'));
    expect(text.body, contains('https://x.com')); // annotation appended
    expect(text.originalCreated, '2020-01-02');

    final list = notes.firstWhere((n) => n.title == 'Groceries');
    expect(list.type, 'checklist');
    expect(list.archived, isTrue);
    expect(list.items.map((i) => i.content).toList(), ['milk', 'eggs']);
    expect(list.items[1].checked, isTrue);
  });

  test('resolves image attachments by basename', () {
    final img = Uint8List.fromList([9, 8, 7, 6]);
    final zip = _zip({
      'Takeout/Keep/pic.png': img,
      'Takeout/Keep/n.json': jsonEncode({
        'title': 'Pic',
        'textContent': '',
        'isTrashed': false,
        'attachments': [
          {'filePath': 'pic.png', 'mimetype': 'image/png'},
        ],
      }),
    });

    final notes = parseKeepTakeout(zip);
    expect(notes.length, 1);
    expect(notes.single.images.length, 1);
    expect(notes.single.images.single, img);
  });
}
