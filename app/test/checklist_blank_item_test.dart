import 'package:flutter_test/flutter_test.dart';

import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/features/notes/note_editor_screen.dart';

/// A blank checklist line only survives while the cursor is in it, and only the
/// *trailing* empties are ever removed — a blank line the user left in the
/// middle stays. `trailingBlankChecklistIds` is the shared decision behind both
/// the focus-loss cleanup and the on-close prune.
void main() {
  ChecklistItemRow item(String id, String content) => ChecklistItemRow(
        id: id,
        note: 'n1',
        content: content,
        checked: false,
        position: 0,
        deleted: false,
        created: null,
        updated: '',
        dirty: false,
      );

  // Default: text comes from the row's stored content.
  List<String> trailing(List<ChecklistItemRow> items) =>
      trailingBlankChecklistIds(items, (it) => it.content);

  test('removes a single trailing blank (the fresh "add" line)', () {
    final items = [item('a', 'milk'), item('b', '')];
    expect(trailing(items), ['b']);
  });

  test('removes a contiguous run of trailing blanks', () {
    final items = [item('a', 'milk'), item('b', ''), item('c', '   ')];
    expect(trailing(items), ['c', 'b']); // from the end inward
  });

  test('keeps a blank in the middle', () {
    final items = [item('a', 'milk'), item('b', ''), item('c', 'eggs')];
    expect(trailing(items), isEmpty);
  });

  test('keeps a middle blank even when the last is also blank', () {
    // Only the trailing run goes; the middle blank is untouched.
    final items = [
      item('a', 'milk'),
      item('b', ''), // middle — kept
      item('c', 'eggs'),
      item('d', ''), // trailing — removed
    ];
    expect(trailing(items), ['d']);
  });

  test('whitespace-only counts as blank', () {
    final items = [item('a', 'milk'), item('b', '  \t ')];
    expect(trailing(items), ['b']);
  });

  test('nothing to remove when the last item has text', () {
    final items = [item('a', 'milk'), item('b', 'eggs')];
    expect(trailing(items), isEmpty);
  });

  test('an all-blank list is fully cleared', () {
    final items = [item('a', ''), item('b', '')];
    expect(trailing(items), ['b', 'a']);
  });

  test('empty list yields nothing', () {
    expect(trailing(const []), isEmpty);
  });

  test('uses the live text override, not stale stored content', () {
    // Stored content is empty, but the live controller shows typed text — the
    // item must NOT be pruned (guards the "lag behind last keystroke" case).
    final items = [item('a', 'milk'), item('b', '')];
    final live = {'b': 'bread'};
    final ids = trailingBlankChecklistIds(
        items, (it) => live[it.id] ?? it.content);
    expect(ids, isEmpty);
  });
}
