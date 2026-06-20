import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/features/backup/snapshot_service.dart';

void main() {
  test('SnapshotContents.parse groups notes by notebook (No notebook last)',
      () {
    final json = utf8.encode(jsonEncode({
      'notebooks': [
        {'id': 'nbWork00000000', 'name': 'Work'},
        {'id': 'nbTrip00000000', 'name': 'Trips'},
        {'id': 'nbGone00000000', 'name': 'Gone', 'deleted': true},
      ],
      'notes': [
        {'id': 'n1', 'title': 'Report', 'notebook': 'nbWork00000000'},
        {'id': 'n2', 'title': 'Lisbon', 'notebook': 'nbTrip00000000'},
        {'id': 'n3', 'title': 'Idea'}, // no notebook
        {'id': 'n4', 'title': 'Old', 'deleted': true}, // excluded
      ],
      'checklistItems': [],
      'attachments': [],
    }));

    final contents = SnapshotContents.parse(json);
    expect(contents.notes.map((n) => n.id), ['n1', 'n2', 'n3']);

    final groups = contents.toPreviewGroups();
    // Named notebooks alphabetical, then "No notebook" last.
    expect(groups.map((g) => g.name), ['Trips', 'Work', 'No notebook']);
    expect(groups.last.notes.single.id, 'n3');
    expect(groups.first.notebookId, 'nbTrip00000000');
  });

  test('toPreviewGroups shows an empty notebook (no notes assigned)', () {
    final json = utf8.encode(jsonEncode({
      'notebooks': [
        {'id': 'nbEmpty0000000', 'name': 'Empty'},
        {'id': 'nbFull00000000', 'name': 'Full'},
      ],
      'notes': [
        {'id': 'n1', 'title': 'Has home', 'notebook': 'nbFull00000000'},
      ],
      'checklistItems': [],
      'attachments': [],
    }));

    final groups = SnapshotContents.parse(json).toPreviewGroups();
    final empty = groups.firstWhere((g) => g.name == 'Empty');
    expect(empty.notes, isEmpty, reason: 'shown even with no notes');
    expect(groups.map((g) => g.name), ['Empty', 'Full']);
  });
}
