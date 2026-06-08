import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../data/notes_repository.dart' show ImportedItem;
import 'import_models.dart';

/// Parses a Google Keep "Takeout" export zip into notes. Pure — no I/O — so it
/// is unit-testable. Active + archived notes are imported; trashed notes are
/// skipped.

/// Maps Keep's color names to the closest key in our curated palette
/// (`note_colors.dart`). Unknown/DEFAULT → '' (no color).
const _keepColors = <String, String>{
  'RED': 'coral',
  'ORANGE': 'peach',
  'YELLOW': 'sand',
  'GREEN': 'sage',
  'TEAL': 'mint',
  'BLUE': 'fog',
  'CERULEAN': 'storm',
  'DARKBLUE': 'storm',
  'PURPLE': 'dusk',
  'PINK': 'blush',
  'BROWN': 'clay',
  'GRAY': 'clay',
};

const _imageExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp'};

List<ParsedNote> parseKeepTakeout(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);

  // Index image attachments by basename so a note's filePath can resolve them.
  final images = <String, Uint8List>{};
  for (final file in archive) {
    if (!file.isFile) continue;
    if (_imageExts.contains(p.extension(file.name).toLowerCase())) {
      images[p.basename(file.name)] =
          Uint8List.fromList(file.content as List<int>);
    }
  }

  final notes = <ParsedNote>[];
  for (final file in archive) {
    if (!file.isFile) continue;
    if (p.extension(file.name).toLowerCase() != '.json') continue;

    Object? decoded;
    try {
      decoded =
          jsonDecode(utf8.decode(file.content as List<int>, allowMalformed: true));
    } catch (_) {
      continue;
    }
    if (decoded is! Map) continue;
    final m = decoded.cast<String, dynamic>();
    // Only Keep note objects (not other Takeout json that may sneak in).
    if (!m.containsKey('textContent') &&
        !m.containsKey('listContent') &&
        !m.containsKey('isTrashed')) {
      continue;
    }
    if (m['isTrashed'] == true) continue; // skip trashed

    final note = _noteFromKeep(m, images);
    if (note != null) notes.add(note);
  }
  return notes;
}

ParsedNote? _noteFromKeep(
    Map<String, dynamic> m, Map<String, Uint8List> images) {
  final title = (m['title'] as String?)?.trim() ?? '';
  final pinned = m['isPinned'] == true;
  final archived = m['isArchived'] == true;
  final color = _keepColors[(m['color'] as String?) ?? 'DEFAULT'] ?? '';

  final labelNames = <String>[];
  for (final l in (m['labels'] as List?) ?? const []) {
    if (l is Map && l['name'] is String) labelNames.add(l['name'] as String);
  }

  final images0 = <Uint8List>[];
  for (final a in (m['attachments'] as List?) ?? const []) {
    if (a is Map && a['filePath'] is String) {
      final bytes = images[p.basename(a['filePath'] as String)];
      if (bytes != null) images0.add(bytes);
    }
  }

  final annotationBlock = _annotations(m['annotations']);
  final created = _usecToDate(m['createdTimestampUsec']);

  // Checklist when listContent is present and non-empty.
  final listContent = m['listContent'];
  if (listContent is List && listContent.isNotEmpty) {
    final items = <ImportedItem>[];
    for (final e in listContent) {
      if (e is Map) {
        items.add(ImportedItem(
            (e['text'] as String?)?.trim() ?? '', e['isChecked'] == true));
      }
    }
    return ParsedNote(
      type: 'checklist',
      title: title,
      body: annotationBlock,
      color: color,
      pinned: pinned,
      archived: archived,
      labelNames: labelNames,
      items: items,
      images: images0,
      originalCreated: created,
    );
  }

  final text = (m['textContent'] as String?)?.trimRight() ?? '';
  final body = [
    if (text.isNotEmpty) text,
    if (annotationBlock.isNotEmpty) annotationBlock,
  ].join('\n\n');

  // Skip wholly-empty notes (no title, body, or image).
  if (title.isEmpty && body.isEmpty && images0.isEmpty) return null;

  return ParsedNote(
    type: 'text',
    title: title,
    body: body,
    color: color,
    pinned: pinned,
    archived: archived,
    labelNames: labelNames,
    images: images0,
    originalCreated: created,
  );
}

/// Renders Keep link annotations (URLs + titles) as a small "Links:" block to
/// append to the note body.
String _annotations(Object? annotations) {
  if (annotations is! List) return '';
  final lines = <String>[];
  for (final a in annotations) {
    if (a is! Map) continue;
    final url = (a['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) continue;
    final t = (a['title'] as String?)?.trim() ?? '';
    lines.add(t.isEmpty ? '- $url' : '- $t — $url');
  }
  if (lines.isEmpty) return '';
  return 'Links:\n${lines.join('\n')}';
}

/// Converts Keep's microsecond epoch timestamp to a `yyyy-MM-dd` date string.
String? _usecToDate(Object? usec) {
  if (usec is! num) return null;
  final dt = DateTime.fromMicrosecondsSinceEpoch(usec.toInt(), isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
}
