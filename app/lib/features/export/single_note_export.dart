import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:printing/printing.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import 'export_delivery.dart';
import 'markdown_export.dart';
import 'note_pdf.dart';
import 'note_plaintext.dart';

/// The export formats offered for a single note.
enum NoteExportFormat { markdown, plainText, pdf }

/// Everything needed to render one note, gathered from the repository.
class _NoteBundle {
  _NoteBundle(this.note, this.items, this.attachments, this.labelNames,
      this.notebookNames);

  final NoteRow note;
  final List<ChecklistItemRow> items;
  final List<AttachmentRow> attachments;
  final Map<String, String> labelNames;
  final Map<String, String> notebookNames;
}

/// Exports a single note in a chosen [NoteExportFormat] and hands it to the
/// platform (share sheet on mobile / download or print dialog on web). Reuses
/// the Markdown renderer used by the bulk export; PDF goes through `printing`,
/// which handles cross-platform delivery itself.
class SingleNoteExporter {
  SingleNoteExporter(this._repo);

  final NotesRepository _repo;

  Future<void> share(String noteId, NoteExportFormat format) async {
    final bundle = await _gather(noteId);
    switch (format) {
      case NoteExportFormat.markdown:
        await _shareMarkdown(bundle);
      case NoteExportFormat.plainText:
        await _sharePlainText(bundle);
      case NoteExportFormat.pdf:
        await _sharePdf(bundle);
    }
  }

  Future<_NoteBundle> _gather(String noteId) async {
    final note = await _repo.watchNote(noteId).first;
    if (note == null) {
      throw StateError('Note $noteId not found');
    }
    final items = note.type == 'checklist'
        ? await _repo.watchItems(noteId).first
        : const <ChecklistItemRow>[];
    final attachments = await _repo.watchAttachments(noteId).first;
    final labels = await _repo.watchLabels().first;
    final notebooks = await _repo.watchNotebooks().first;
    return _NoteBundle(
      note,
      items,
      attachments,
      {for (final l in labels) l.id: l.name},
      {for (final n in notebooks) n.id: n.name},
    );
  }

  Future<void> _shareMarkdown(_NoteBundle b) async {
    final md = buildNoteMarkdown(
      note: b.note,
      items: b.items,
      attachments: b.attachments,
      labelNames: b.labelNames,
      notebookNames: b.notebookNames,
    );
    final mdBytes = utf8.encode(md);
    final slug = noteSlug(b.note);
    final liveAtt =
        b.attachments.where((a) => !a.deleted && a.data != null).toList();

    // No images → a bare .md; otherwise bundle md + attachments in a zip so the
    // relative image links resolve (same layout as the bulk export).
    if (liveAtt.isEmpty) {
      await deliverBytes(
          Uint8List.fromList(mdBytes), '$slug.md', 'text/markdown');
      return;
    }
    final archive = Archive()
      ..addFile(ArchiveFile('$slug.md', mdBytes.length, mdBytes));
    for (final att in liveAtt) {
      final bytes = att.data!;
      archive.addFile(ArchiveFile(
          'attachments/${attachmentFileName(att)}', bytes.length, bytes));
    }
    final zip = ZipEncoder().encodeBytes(archive);
    await deliverBytes(zip, '$slug.zip', 'application/zip');
  }

  Future<void> _sharePlainText(_NoteBundle b) async {
    final text = buildNotePlainText(note: b.note, items: b.items);
    await deliverBytes(Uint8List.fromList(utf8.encode(text)),
        '${noteSlug(b.note)}.txt', 'text/plain');
  }

  Future<void> _sharePdf(_NoteBundle b) async {
    final bytes = await buildNotePdf(
      note: b.note,
      items: b.items,
      attachments: b.attachments,
      labelNames: b.labelNames,
      notebookNames: b.notebookNames,
    );
    await Printing.sharePdf(bytes: bytes, filename: '${noteSlug(b.note)}.pdf');
  }
}
