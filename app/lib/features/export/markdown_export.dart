import '../../data/local/database.dart';
import '../../data/notes_repository.dart' show labelIdsOf;

/// Pure Markdown rendering for note export. No I/O here so it stays trivially
/// unit-testable; [NoteExportService] handles gathering data and zipping.

/// A short, filesystem-safe slug derived from a note's title (falling back to
/// its id). Keeps the id suffix so two same-titled notes never collide.
String noteSlug(NoteRow note) {
  final base = note.title.trim().toLowerCase();
  final cleaned = base
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final shortId = note.id.length <= 6 ? note.id : note.id.substring(0, 6);
  if (cleaned.isEmpty) return 'note-$shortId';
  final trimmed = cleaned.length <= 40 ? cleaned : cleaned.substring(0, 40);
  return '$trimmed-$shortId';
}

/// Export filename (within `attachments/`) for an image attachment.
String attachmentFileName(AttachmentRow att) => '${att.id}.jpg';

/// Escapes a value for safe inclusion in a double-quoted YAML scalar.
String _yamlString(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Renders a single note as a Markdown document: YAML frontmatter (title,
/// labels, color, pinned, timestamps) followed by the body. Checklist notes
/// render as GitHub task lists; image attachments render as relative links into
/// the export's `attachments/` folder.
///
/// [labelNames] maps label id → name; ids without a known name are skipped.
/// [notebookNames] maps notebook id → name; an unknown id omits the field.
String buildNoteMarkdown({
  required NoteRow note,
  required List<ChecklistItemRow> items,
  required List<AttachmentRow> attachments,
  required Map<String, String> labelNames,
  Map<String, String> notebookNames = const {},
}) {
  final buf = StringBuffer();

  // ---- Frontmatter ----
  buf.writeln('---');
  buf.writeln('title: ${_yamlString(note.title)}');

  final labels = labelIdsOf(note)
      .map((id) => labelNames[id])
      .whereType<String>()
      .toList();
  if (labels.isNotEmpty) {
    buf.writeln('labels: [${labels.map(_yamlString).join(', ')}]');
  }
  final notebookName = notebookNames[note.notebook];
  if (notebookName != null && notebookName.isNotEmpty) {
    buf.writeln('notebook: ${_yamlString(notebookName)}');
  }
  if (note.color.isNotEmpty) buf.writeln('color: ${_yamlString(note.color)}');
  if (note.pinned) buf.writeln('pinned: true');
  if (note.archived) buf.writeln('archived: true');
  if ((note.created ?? '').isNotEmpty) {
    buf.writeln('created: ${_yamlString(note.created!)}');
  }
  if (note.updated.isNotEmpty) {
    buf.writeln('updated: ${_yamlString(note.updated)}');
  }
  buf.writeln('---');
  buf.writeln();

  // ---- Heading ----
  if (note.title.trim().isNotEmpty) {
    buf.writeln('# ${note.title.trim()}');
    buf.writeln();
  }

  // ---- Body ----
  if (note.type == 'checklist') {
    final live = items.where((i) => !i.deleted).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    for (final item in live) {
      buf.writeln('- [${item.checked ? 'x' : ' '}] ${item.content}');
    }
    if (live.isNotEmpty) buf.writeln();
  } else if (note.body.trim().isNotEmpty) {
    buf.writeln(note.body.trimRight());
    buf.writeln();
  }

  // ---- Attachments ----
  final liveAtt = attachments.where((a) => !a.deleted && a.data != null);
  for (final att in liveAtt) {
    buf.writeln('![](attachments/${attachmentFileName(att)})');
  }

  return buf.toString();
}
