import 'dart:typed_data';

import '../../data/notes_repository.dart' show ImportedItem;

/// A note parsed from an external source (our Markdown export, loose `.md`
/// files, or a Google Keep Takeout). Labels and the notebook are kept as
/// *names* here; the import service resolves them to ids (find-or-create)
/// against the current account before writing.
class ParsedNote {
  const ParsedNote({
    required this.type,
    this.title = '',
    this.body = '',
    this.color = '',
    this.pinned = false,
    this.archived = false,
    this.labelNames = const [],
    this.notebookName,
    this.items = const [],
    this.images = const [],
    this.originalCreated,
  });

  final String type; // 'text' | 'checklist'
  final String title;
  final String body;
  final String color;
  final bool pinned;
  final bool archived;
  final List<String> labelNames;
  final String? notebookName;
  final List<ImportedItem> items;
  final List<Uint8List> images;

  /// The note's original creation timestamp from the source, if known. Parsed
  /// from the source but not currently written anywhere — the backend assigns
  /// its own `created` on import, and we no longer footnote the original into
  /// the body (it cluttered every imported note).
  final String? originalCreated;
}

/// Outcome of an import run.
class ImportResult {
  const ImportResult(this.imported, this.skipped);
  final int imported;
  final int skipped;
}
