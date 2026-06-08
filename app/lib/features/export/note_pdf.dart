import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/local/database.dart';
import '../../data/notes_repository.dart' show labelIdsOf;

/// Renders a single note to a PDF document and returns its bytes. Title, an
/// optional labels line, then the body (or checklist as ☑/☐ lines), followed
/// by any image attachments. Uses a [pw.MultiPage] so long notes paginate.
Future<Uint8List> buildNotePdf({
  required NoteRow note,
  required List<ChecklistItemRow> items,
  required List<AttachmentRow> attachments,
  Map<String, String> labelNames = const {},
  Map<String, String> notebookNames = const {},
}) async {
  final doc = pw.Document();

  final live = items.where((i) => !i.deleted).toList()
    ..sort((a, b) => a.position.compareTo(b.position));
  final images = attachments
      .where((a) => !a.deleted && a.data != null)
      .map((a) => pw.MemoryImage(a.data!))
      .toList();

  final labels = labelIdsOf(note)
      .map((id) => labelNames[id])
      .whereType<String>()
      .toList();
  final title = note.title.trim();

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => [
        if (title.isNotEmpty)
          pw.Text(title,
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
        if (labels.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(labels.join(' · '),
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          ),
        if (title.isNotEmpty || labels.isNotEmpty) pw.SizedBox(height: 12),
        if (note.type == 'checklist')
          ...live.map(
            (item) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(item.checked ? '☑ ' : '☐ '),
                  pw.Expanded(
                    child: pw.Text(
                      item.content,
                      style: item.checked
                          ? const pw.TextStyle(
                              decoration: pw.TextDecoration.lineThrough,
                              color: PdfColors.grey600)
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (note.body.trim().isNotEmpty)
          pw.Text(note.body.trimRight()),
        for (final img in images)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 12),
            child: pw.Image(img),
          ),
      ],
    ),
  );

  return doc.save();
}
