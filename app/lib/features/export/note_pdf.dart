import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/local/database.dart';
import '../../data/notes_repository.dart' show labelIdsOf;
import 'markdown_pdf.dart';
import 'pdf_fonts.dart';

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
  final fonts = await PdfFonts.load();
  final doc = pw.Document(theme: fonts.theme);

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
                  _checkbox(item.checked),
                  pw.SizedBox(width: 6),
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
          ...markdownToPdfWidgets(note.body, mono: fonts.mono),
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

/// A drawn checkbox (a bordered square, with a tick when [checked]) — drawn
/// rather than a ☑/☐ glyph, which the bundled Roboto doesn't include.
pw.Widget _checkbox(bool checked) => pw.Container(
      width: 11,
      height: 11,
      margin: const pw.EdgeInsets.only(top: 2),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey700, width: 0.8),
        borderRadius: pw.BorderRadius.circular(2),
        color: checked ? PdfColors.grey700 : null,
      ),
      child: checked
          ? pw.Center(
              child: pw.Text('x',
                  style: pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold)))
          : null,
    );
