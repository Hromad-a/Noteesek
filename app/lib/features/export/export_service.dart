import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import 'markdown_export.dart';

/// Builds a single `.zip` bundle of all notes as Markdown, suitable for the
/// share sheet (mobile) or a browser download (web). Pure data work + zipping;
/// platform delivery lives in `export_delivery.dart`.
class NoteExportService {
  NoteExportService(this._repo);

  final NotesRepository _repo;

  /// Active + archived notes are exported; trashed notes are excluded.
  ///
  /// Returns the zip bytes, or `null` if there are no notes to export.
  Future<Uint8List?> buildZip() async {
    final active = await _repo.watchActive().first;
    final archived = await _repo.watchArchived().first;
    final notes = [...active, ...archived];
    if (notes.isEmpty) return null;

    final labels = await _repo.watchLabels().first;
    final labelNames = {for (final l in labels) l.id: l.name};

    final archive = Archive();
    final usedNames = <String>{};

    for (final note in notes) {
      final items = note.type == 'checklist'
          ? await _repo.watchItems(note.id).first
          : const <ChecklistItemRow>[];
      final attachments = await _repo.watchAttachments(note.id).first;

      final md = buildNoteMarkdown(
        note: note,
        items: items,
        attachments: attachments,
        labelNames: labelNames,
      );

      final fileName = _uniqueName(usedNames, noteSlug(note));
      final mdBytes = utf8.encode(md);
      archive.addFile(ArchiveFile('notes/$fileName.md', mdBytes.length, mdBytes));

      for (final att in attachments) {
        if (att.deleted || att.data == null) continue;
        final bytes = att.data!;
        archive.addFile(ArchiveFile(
          'attachments/${attachmentFileName(att)}',
          bytes.length,
          bytes,
        ));
      }
    }

    return ZipEncoder().encodeBytes(archive);
  }

  String _uniqueName(Set<String> used, String base) {
    var name = base;
    var n = 2;
    while (!used.add(name)) {
      name = '$base-$n';
      n++;
    }
    return name;
  }
}

/// Suggested download/share filename for an export produced now.
String exportFileName([DateTime? now]) {
  final d = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'noteesek-export-${d.year}${two(d.month)}${two(d.day)}.zip';
}
