import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/database.dart';
import 'package:noteesek/data/notes_repository.dart';

NoteRow _note(
  String id, {
  String type = 'text',
  String color = '',
  String labels = '[]',
}) =>
    NoteRow(
      id: id,
      owner: 'local',
      type: type,
      title: '',
      body: '',
      pinned: false,
      archived: false,
      color: color,
      labels: labels,
      notebook: '',
      lockedBy: '',
      lockedAt: '',
      deleted: false,
      created: '2026-06-05 00:00:00.000Z',
      updated: '2026-06-06 00:00:00.000Z',
      dirty: false,
      position: 0,
    );

List<String> _ids(List<NoteRow> notes) => notes.map((n) => n.id).toList();

void main() {
  final a = _note('a', color: 'coral', labels: '["l1"]');
  final b = _note('b', type: 'checklist', labels: '["l1","l2"]');
  final c = _note('c', color: 'mint');
  final all = [a, b, c];

  test('no active filters returns the list unchanged', () {
    expect(applySearchFilters(all, const SearchFilters(), {}), all);
  });

  test('color filter is exact', () {
    final r = applySearchFilters(all, const SearchFilters(color: 'coral'), {});
    expect(_ids(r), ['a']);
  });

  test('type filter keeps only that type', () {
    final r =
        applySearchFilters(all, const SearchFilters(type: 'checklist'), {});
    expect(_ids(r), ['b']);
  });

  test('labels match by OR', () {
    final r =
        applySearchFilters(all, const SearchFilters(labelIds: {'l2'}), {});
    expect(_ids(r), ['b']);
    final r2 = applySearchFilters(
        all, const SearchFilters(labelIds: {'l1', 'l2'}), {});
    expect(_ids(r2), ['a', 'b']);
  });

  test('hasImage filters by the provided id set', () {
    final r =
        applySearchFilters(all, const SearchFilters(hasImage: true), {'c'});
    expect(_ids(r), ['c']);
  });

  test('filters combine (AND across dimensions)', () {
    final r = applySearchFilters(
        all, const SearchFilters(labelIds: {'l1'}, color: 'coral'), {});
    expect(_ids(r), ['a']);
  });
}
