import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../data/notes_repository.dart' show ImportedItem;
import 'import_models.dart';

/// Parses an imported Markdown payload into notes. Accepts either our own export
/// zip (`notes/*.md` + `attachments/*`) or a single loose `.md` file. Pure —
/// no I/O — so it is straightforward to unit-test.

final _taskItem = RegExp(r'^\s*[-*] \[([ xX])\] (.*)$');
final _imageRef = RegExp(r'^!\[[^\]]*\]\(attachments/(.+)\)\s*$');
final _quoted = RegExp(r'"((?:[^"\\]|\\.)*)"');

bool _looksLikeZip(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B; // 'PK'

/// Dispatches by content/extension: a zip (our export) vs a loose `.md` file.
List<ParsedNote> parseMarkdownImport(Uint8List bytes, String filename) {
  if (_looksLikeZip(bytes) || p.extension(filename).toLowerCase() == '.zip') {
    return parseMarkdownZip(bytes);
  }
  return [
    parseMarkdownDocument(utf8.decode(bytes, allowMalformed: true),
        fallbackTitle: p.basenameWithoutExtension(filename)),
  ];
}

/// Parses our export zip: every `notes/*.md` becomes a note, with image links
/// resolved against the zip's `attachments/` folder.
List<ParsedNote> parseMarkdownZip(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);

  final attachments = <String, Uint8List>{};
  for (final file in archive) {
    if (!file.isFile) continue;
    if (p.split(file.name).contains('attachments')) {
      attachments[p.basename(file.name)] =
          Uint8List.fromList(file.content as List<int>);
    }
  }

  final notes = <ParsedNote>[];
  for (final file in archive) {
    if (!file.isFile) continue;
    if (p.extension(file.name).toLowerCase() != '.md') continue;
    final text = utf8.decode(file.content as List<int>, allowMalformed: true);
    notes.add(parseMarkdownDocument(
      text,
      attachments: attachments,
      fallbackTitle: p.basenameWithoutExtension(file.name),
    ));
  }
  return notes;
}

/// Parses one Markdown document (optionally with YAML frontmatter as written by
/// our exporter). [attachments] maps an image basename → bytes for `![](…)`
/// references; [fallbackTitle] is used when no title can be derived.
ParsedNote parseMarkdownDocument(
  String markdown, {
  Map<String, Uint8List> attachments = const {},
  String? fallbackTitle,
}) {
  final lines = const LineSplitter().convert(markdown);

  // ---- Frontmatter ----
  final front = <String, String>{};
  var i = 0;
  while (i < lines.length && lines[i].trim().isEmpty) {
    i++;
  }
  if (i < lines.length && lines[i].trim() == '---') {
    i++;
    while (i < lines.length && lines[i].trim() != '---') {
      final line = lines[i];
      final colon = line.indexOf(':');
      if (colon > 0) {
        front[line.substring(0, colon).trim()] =
            line.substring(colon + 1).trim();
      }
      i++;
    }
    if (i < lines.length) i++; // closing '---'
  }

  var title = _unquote(front['title'] ?? '');
  final labelNames = _parseList(front['labels'] ?? '');
  final notebookName = _unquote(front['notebook'] ?? '');
  final color = _unquote(front['color'] ?? '');
  final pinned = (front['pinned'] ?? '').trim() == 'true';
  final archived = (front['archived'] ?? '').trim() == 'true';
  final created = _unquote(front['created'] ?? '');

  // ---- Body ----
  final body = lines.sublist(i);
  // Drop a leading blank run, then a leading "# heading" (the exporter writes
  // the title both as frontmatter and as an H1).
  var b = 0;
  while (b < body.length && body[b].trim().isEmpty) {
    b++;
  }
  if (b < body.length && body[b].startsWith('# ')) {
    final heading = body[b].substring(2).trim();
    if (title.isEmpty) title = heading;
    b++;
  }

  final images = <Uint8List>[];
  final taskItems = <ImportedItem>[];
  final textLines = <String>[];
  var sawNonTask = false;
  var sawTask = false;

  for (final raw in body.sublist(b)) {
    final img = _imageRef.firstMatch(raw);
    if (img != null) {
      final bytes = attachments[img.group(1)];
      if (bytes != null) images.add(bytes);
      continue;
    }
    final task = _taskItem.firstMatch(raw);
    if (task != null) {
      sawTask = true;
      taskItems.add(ImportedItem(
          task.group(2)!.trim(), task.group(1)!.toLowerCase() == 'x'));
      continue;
    }
    if (raw.trim().isNotEmpty) sawNonTask = true;
    textLines.add(raw);
  }

  if (title.isEmpty) title = (fallbackTitle ?? '').trim();

  // A note is a checklist when its content is task items only.
  if (sawTask && !sawNonTask) {
    return ParsedNote(
      type: 'checklist',
      title: title,
      color: color,
      pinned: pinned,
      archived: archived,
      labelNames: labelNames,
      notebookName: notebookName.isEmpty ? null : notebookName,
      items: taskItems,
      images: images,
      originalCreated: created.isEmpty ? null : created,
    );
  }

  return ParsedNote(
    type: 'text',
    title: title,
    body: textLines.join('\n').trim(),
    color: color,
    pinned: pinned,
    archived: archived,
    labelNames: labelNames,
    notebookName: notebookName.isEmpty ? null : notebookName,
    images: images,
    originalCreated: created.isEmpty ? null : created,
  );
}

/// Unescapes a double-quoted YAML scalar (the inverse of the exporter's
/// `_yamlString`). Returns the value unchanged when not quoted.
String _unquote(String value) {
  final v = value.trim();
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    return v
        .substring(1, v.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }
  return v;
}

/// Parses a YAML inline list of quoted strings: `["a", "b"]` → `['a', 'b']`.
List<String> _parseList(String value) => _quoted
    .allMatches(value)
    .map((m) => m.group(1)!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\'))
    .toList();
