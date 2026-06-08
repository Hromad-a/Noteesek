import '../../data/notes_repository.dart';
import 'import_models.dart';

/// Writes [ParsedNote]s into the repository, resolving label/notebook *names*
/// to ids (creating any that don't exist yet) and preserving the source's
/// original creation date as a body footnote (the backend assigns its own
/// `created`). Works against either repository implementation, so imports run
/// on both mobile (local DB → synced later) and web (straight to PocketBase).
class NoteImportService {
  NoteImportService(this._repo);

  final NotesRepository _repo;

  Future<ImportResult> import(List<ParsedNote> notes) async {
    if (notes.isEmpty) return const ImportResult(0, 0);

    // Seed find-or-create caches from what already exists (case-insensitive).
    final labelIds = <String, String>{
      for (final l in await _repo.watchLabels().first) l.name.toLowerCase(): l.id
    };
    final notebookIds = <String, String>{
      for (final n in await _repo.watchNotebooks().first)
        n.name.toLowerCase(): n.id
    };

    Future<String> labelId(String name) async {
      final key = name.toLowerCase();
      return labelIds[key] ??= await _repo.createLabel(name);
    }

    Future<String> notebookId(String name) async {
      final key = name.toLowerCase();
      return notebookIds[key] ??= await _repo.createNotebook(name);
    }

    var imported = 0;
    for (final note in notes) {
      final ids = <String>[];
      for (final name in note.labelNames) {
        if (name.trim().isEmpty) continue;
        ids.add(await labelId(name.trim()));
      }
      final notebook = (note.notebookName != null &&
              note.notebookName!.trim().isNotEmpty)
          ? await notebookId(note.notebookName!.trim())
          : '';

      await _repo.importNote(NoteImport(
        type: note.type,
        title: note.title,
        body: _bodyWithFootnote(note),
        pinned: note.pinned,
        archived: note.archived,
        color: note.color,
        labelIds: ids,
        notebook: notebook,
        items: note.items,
        images: note.images,
      ));
      imported++;
    }
    return ImportResult(imported, 0);
  }

  /// Appends the source's original creation date to the body (the backend can't
  /// preserve `created`, so we keep it visible/searchable here instead).
  String _bodyWithFootnote(ParsedNote note) {
    final created = note.originalCreated;
    if (created == null || created.trim().isEmpty) return note.body;
    final footnote = '_Imported — originally created ${created.trim()}_';
    return note.body.trim().isEmpty
        ? footnote
        : '${note.body.trimRight()}\n\n$footnote';
  }
}
