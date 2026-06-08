import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/features/export/markdown_export.dart';

NoteRow _note({
  String id = 'note0000000001',
  String type = 'text',
  String title = '',
  String body = '',
  bool pinned = false,
  bool archived = false,
  String color = '',
  String labels = '[]',
  String notebook = '',
}) =>
    NoteRow(
      id: id,
      owner: 'local',
      type: type,
      title: title,
      body: body,
      pinned: pinned,
      archived: archived,
      color: color,
      labels: labels,
      notebook: notebook,
      deleted: false,
      created: '2026-06-05 00:00:00.000Z',
      updated: '2026-06-06 00:00:00.000Z',
      dirty: false,
      position: 0,
    );

ChecklistItemRow _item(String id, String content, bool checked, int pos) =>
    ChecklistItemRow(
      id: id,
      note: 'note0000000001',
      content: content,
      checked: checked,
      position: pos,
      deleted: false,
      updated: '',
      dirty: false,
    );

AttachmentRow _att(String id, {Uint8List? data, bool deleted = false}) =>
    AttachmentRow(
      id: id,
      note: 'note0000000001',
      file: '',
      data: data,
      deleted: deleted,
      updated: '',
      dirty: false,
    );

void main() {
  group('noteSlug', () {
    test('slugifies title and keeps an id suffix', () {
      final slug = noteSlug(_note(id: 'abc123xyz00000', title: 'My Groceries!'));
      expect(slug, 'my-groceries-abc123');
    });

    test('falls back to note-<id> for empty titles', () {
      expect(noteSlug(_note(id: 'abc123xyz00000', title: '   ')),
          'note-abc123');
    });
  });

  group('buildNoteMarkdown', () {
    test('text note: frontmatter + heading + body', () {
      final md = buildNoteMarkdown(
        note: _note(
          title: 'Shopping',
          body: 'milk and bread',
          pinned: true,
          color: 'purple',
          labels: '["l1","l2"]',
        ),
        items: const [],
        attachments: const [],
        labelNames: {'l1': 'home', 'l2': 'errands'},
      );

      expect(md, contains('title: "Shopping"'));
      expect(md, contains('labels: ["home", "errands"]'));
      expect(md, contains('color: "purple"'));
      expect(md, contains('pinned: true'));
      expect(md, contains('# Shopping'));
      expect(md, contains('milk and bread'));
    });

    test('checklist note renders task lists in position order', () {
      final md = buildNoteMarkdown(
        note: _note(type: 'checklist', title: 'Todo'),
        items: [
          _item('i2', 'second', true, 1),
          _item('i1', 'first', false, 0),
        ],
        attachments: const [],
        labelNames: const {},
      );

      final firstIdx = md.indexOf('- [ ] first');
      final secondIdx = md.indexOf('- [x] second');
      expect(firstIdx, greaterThanOrEqualTo(0));
      expect(secondIdx, greaterThan(firstIdx));
    });

    test('embeds only non-deleted attachments that have bytes', () {
      final md = buildNoteMarkdown(
        note: _note(),
        items: const [],
        attachments: [
          _att('keep01', data: Uint8List.fromList([1, 2, 3])),
          _att('nodata'),
          _att('gone00', data: Uint8List.fromList([4]), deleted: true),
        ],
        labelNames: const {},
      );

      expect(md, contains('![](attachments/keep01.jpg)'));
      expect(md, isNot(contains('nodata')));
      expect(md, isNot(contains('gone00')));
    });

    test('unknown label ids are skipped', () {
      final md = buildNoteMarkdown(
        note: _note(labels: '["known","missing"]'),
        items: const [],
        attachments: const [],
        labelNames: {'known': 'work'},
      );
      expect(md, contains('labels: ["work"]'));
    });

    test('notebook name is written when known, omitted otherwise', () {
      final withName = buildNoteMarkdown(
        note: _note(notebook: 'nb1'),
        items: const [],
        attachments: const [],
        labelNames: const {},
        notebookNames: {'nb1': 'Work'},
      );
      expect(withName, contains('notebook: "Work"'));

      final unknown = buildNoteMarkdown(
        note: _note(notebook: 'nb1'),
        items: const [],
        attachments: const [],
        labelNames: const {},
        notebookNames: const {},
      );
      expect(unknown, isNot(contains('notebook:')));
    });
  });
}
