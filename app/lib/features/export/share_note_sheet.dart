import 'package:flutter/material.dart';

import '../../data/notes_repository.dart';
import 'single_note_export.dart';

/// Shows the single-note export-format chooser (Markdown / plain text / PDF) in
/// a bottom sheet and hands the chosen format to [SingleNoteExporter]. Shared by
/// the note editor's overflow menu and the grid's selection action bar.
Future<void> showShareNoteSheet(
  BuildContext context,
  NotesRepository repo,
  String noteId,
) async {
  final format = await showModalBottomSheet<NoteExportFormat>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Markdown'),
            onTap: () =>
                Navigator.of(sheetContext).pop(NoteExportFormat.markdown),
          ),
          ListTile(
            leading: const Icon(Icons.notes_outlined),
            title: const Text('Plain text'),
            onTap: () =>
                Navigator.of(sheetContext).pop(NoteExportFormat.plainText),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF'),
            onTap: () => Navigator.of(sheetContext).pop(NoteExportFormat.pdf),
          ),
        ],
      ),
    ),
  );
  if (format == null) return;
  try {
    await SingleNoteExporter(repo).share(noteId, format);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Share failed: $e')));
    }
  }
}
