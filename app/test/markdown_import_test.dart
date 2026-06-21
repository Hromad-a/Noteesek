import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/features/export/markdown_export.dart';
import 'package:noteesek/features/import/markdown_import.dart';

NoteRow _note({
  String type = 'text',
  String title = '',
  String body = '',
  bool pinned = false,
  String color = '',
  String labels = '[]',
  String notebook = 'nb1',
}) =>
    NoteRow(
      id: 'note0000000001',
      owner: 'local',
      type: type,
      title: title,
      body: body,
      pinned: pinned,
      archived: false,
      color: color,
      labels: labels,
      notebook: notebook,
      lockedBy: '',
      lockedAt: '',
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

void main() {
  group('parseMarkdownDocument round-trips the exporter', () {
    test('text note: title, body, color, pinned, labels, notebook', () {
      final md = buildNoteMarkdown(
        note: _note(
          title: 'Shopping',
          body: 'milk and bread',
          pinned: true,
          color: 'coral',
          labels: '["l1","l2"]',
        ),
        items: const [],
        attachments: const [],
        labelNames: {'l1': 'home', 'l2': 'errands'},
        notebookNames: {'nb1': 'Work'},
      );

      final p = parseMarkdownDocument(md);
      expect(p.type, 'text');
      expect(p.title, 'Shopping');
      expect(p.body, 'milk and bread');
      expect(p.color, 'coral');
      expect(p.pinned, isTrue);
      expect(p.labelNames, ['home', 'errands']);
      expect(p.notebookName, 'Work');
      expect(p.originalCreated, '2026-06-05 00:00:00.000Z');
    });

    test('checklist note is detected and items preserved', () {
      final md = buildNoteMarkdown(
        note: _note(type: 'checklist', title: 'Todo'),
        items: [
          _item('i1', 'first', false, 0),
          _item('i2', 'second', true, 1),
        ],
        attachments: const [],
        labelNames: const {},
      );

      final p = parseMarkdownDocument(md);
      expect(p.type, 'checklist');
      expect(p.title, 'Todo');
      expect(p.items.map((i) => i.content).toList(), ['first', 'second']);
      expect(p.items.map((i) => i.checked).toList(), [false, true]);
    });
  });

  group('loose .md files (no frontmatter)', () {
    test('title from H1, rest is body', () {
      final p = parseMarkdownDocument('# My Note\n\nhello world');
      expect(p.type, 'text');
      expect(p.title, 'My Note');
      expect(p.body, 'hello world');
    });

    test('no H1 → untitled (filename is never used as the title)', () {
      final p = parseMarkdownDocument('just some body text');
      expect(p.type, 'text');
      expect(p.title, '');
      expect(p.body, 'just some body text');
    });

    test('task-list-only file becomes a checklist, left untitled', () {
      final p = parseMarkdownDocument('- [ ] a\n- [x] b');
      expect(p.type, 'checklist');
      expect(p.title, '');
      expect(p.items.length, 2);
      expect(p.items[1].checked, isTrue);
    });

    test('mixed task + prose stays a text note', () {
      final p = parseMarkdownDocument('intro line\n- [ ] a');
      expect(p.type, 'text');
      expect(p.body, contains('intro line'));
    });
  });
}
