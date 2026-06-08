import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/features/export/note_plaintext.dart';

NoteRow _note({
  String type = 'text',
  String title = '',
  String body = '',
}) =>
    NoteRow(
      id: 'note0000000001',
      owner: 'local',
      type: type,
      title: title,
      body: body,
      pinned: false,
      archived: false,
      color: '',
      labels: '[]',
      notebook: '',
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
  group('buildNotePlainText', () {
    test('text note: title then body, no markdown syntax', () {
      final text = buildNotePlainText(
        note: _note(title: 'Shopping', body: 'milk and bread'),
        items: const [],
      );
      expect(text, 'Shopping\n\nmilk and bread');
    });

    test('checklist renders ☑/☐ in position order', () {
      final text = buildNotePlainText(
        note: _note(type: 'checklist', title: 'Todo'),
        items: [
          _item('i2', 'second', true, 1),
          _item('i1', 'first', false, 0),
        ],
      );
      expect(text, 'Todo\n\n☐ first\n☑ second');
    });

    test('untitled text note is just the body', () {
      final text = buildNotePlainText(
        note: _note(body: 'just a thought'),
        items: const [],
      );
      expect(text, 'just a thought');
    });
  });
}
