import 'dart:convert';

import 'package:drift/drift.dart' show Uint8List;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../providers.dart';
import 'local/database.dart';
import 'local_notes_repository.dart';
import 'remote_notes_repository.dart';

/// Decodes a JSON-array string of label ids into a (mutable) list. Tolerant of
/// malformed/empty values (returns an empty list).
List<String> labelIdsOfRaw(String raw) {
  if (raw.isEmpty) return [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded.map((e) => e.toString()).toList();
  } catch (_) {/* fall through */}
  return [];
}

/// Decodes a note's [NoteRow.labels] into its assigned label ids.
List<String> labelIdsOf(NoteRow note) => labelIdsOfRaw(note.labels);

/// Encodes label ids into the JSON-array string stored on a note.
String encodeLabelIds(List<String> ids) => jsonEncode(ids);

/// Resolves which notebook a note effectively belongs to: its own [NoteRow.notebook]
/// when that points at a known (non-deleted) notebook, otherwise the default
/// notebook. This makes "default" a safe catch-all — notes whose notebook was
/// deleted (or was never set) surface in the default notebook instead of
/// vanishing.
String effectiveNotebookId(
    NoteRow note, Set<String> knownNotebookIds, String defaultNotebookId) {
  if (note.notebook.isNotEmpty && knownNotebookIds.contains(note.notebook)) {
    return note.notebook;
  }
  return defaultNotebookId;
}

/// Abstraction over note storage. Two implementations:
/// - [LocalNotesRepository] (mobile): offline-first drift DB + sync.
/// - [RemoteNotesRepository] (web): online-only, direct PocketBase API.
///
/// Both speak in the same drift row models ([NoteRow], [ChecklistItemRow],
/// [AttachmentRow]) so the UI is platform-agnostic.
abstract interface class NotesRepository {
  // Notes — queries
  Stream<List<NoteRow>> watchActive();
  Stream<List<NoteRow>> watchArchived();
  Stream<List<NoteRow>> watchTrash();
  Stream<NoteRow?> watchNote(String id);
  Stream<List<NoteRow>> searchActive(String raw);

  // Notes — mutations

  /// Create a note in [notebook] (empty = default). Stamped with the active
  /// owner and appended to the end of its section.
  Future<String> createNote({required String type, String notebook});
  Future<void> updateNoteFields(String id, {String? title, String? body});
  Future<void> setPinned(String id, bool pinned);
  Future<void> setArchived(String id, bool archived);
  Future<void> setColor(String id, String color);
  Future<void> softDelete(String id);
  Future<void> restore(String id);

  /// Convert a note between 'text' and 'checklist', migrating content in place:
  /// non-blank body lines become checklist items and vice-versa. No-op if the
  /// note is already [type].
  Future<void> convertNoteType(String id, String type);

  /// Reassign positions so [orderedIds] is sorted 0…n within its section
  /// (pinned or unpinned — caller passes only IDs from one section).
  Future<void> reorderNotes(List<String> orderedIds);
  Future<void> deleteForever(String noteId);
  Future<List<String>> trashedNoteIds();

  /// Reassign locally-owned notes to [userId] when connecting a server.
  /// No-op for the remote (web) implementation.
  Future<void> claimLocalNotes(String userId);

  // Labels
  Stream<List<LabelRow>> watchLabels();
  Future<String> createLabel(String name);
  Future<void> renameLabel(String id, String name);

  /// Soft-delete a label and remove its id from every note that carries it.
  Future<void> deleteLabel(String id);

  /// Replace a note's assigned labels with [labelIds].
  Future<void> setNoteLabels(String noteId, List<String> labelIds);

  // Notebooks
  Stream<List<NotebookRow>> watchNotebooks();

  /// Ensure the active owner has exactly one default notebook, creating it
  /// (named "Notebook") if absent and reconciling duplicates down to the
  /// earliest-created one. Returns the default notebook's id.
  Future<String> ensureDefaultNotebook();

  Future<String> createNotebook(String name);
  Future<void> renameNotebook(String id, String name);

  /// Soft-delete a notebook. Its notes are either reassigned to the default
  /// notebook ([moveNotesToDefault] = true) or soft-deleted to Trash.
  Future<void> deleteNotebook(String id, {required bool moveNotesToDefault});

  /// Move a note into [notebookId].
  Future<void> setNoteNotebook(String noteId, String notebookId);

  // Checklist items
  Stream<List<ChecklistItemRow>> watchItems(String noteId);
  Future<String> addItem(String noteId, {String content});
  Future<void> setItemContent(String id, String content);
  Future<void> setItemChecked(String id, bool checked);
  Future<void> deleteItem(String id);

  // Attachments
  Stream<List<AttachmentRow>> watchAttachments(String noteId);
  Future<String> addAttachment(String noteId, Uint8List bytes);
  Future<void> deleteAttachment(String id);
}

/// Selects the implementation by platform: web talks directly to the server,
/// mobile uses the local-first drift store.
final notesRepositoryProvider = Provider<NotesRepository>((ref) {
  if (kIsWeb) {
    final pb = ref.watch(pocketBaseProvider);
    final repo = RemoteNotesRepository(pb);
    ref.onDispose(repo.dispose);
    return repo;
  }
  final db = ref.watch(databaseProvider);
  final owner = ref.watch(activeOwnerProvider);
  return LocalNotesRepository(db, owner);
});

/// Current search query for the notes grid.
class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

final searchQueryProvider =
    NotifierProvider<SearchQueryNotifier, String>(SearchQueryNotifier.new);

/// All of the user's (non-deleted) notebooks, ordered oldest-first so the
/// default notebook stays at the top.
final notebooksProvider = StreamProvider<List<NotebookRow>>((ref) {
  return ref.watch(notesRepositoryProvider).watchNotebooks();
});

/// The default notebook's id (the `isDefault` row), or '' until one exists.
final defaultNotebookIdProvider = Provider<String>((ref) {
  final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
  for (final nb in notebooks) {
    if (nb.isDefault) return nb.id;
  }
  return notebooks.isNotEmpty ? notebooks.first.id : '';
});

/// The notebook id the user last selected (persisted). Empty = default.
class SelectedNotebookNotifier extends Notifier<String> {
  @override
  String build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(AppConfig.kSelectedNotebook) ?? '';
  }

  Future<void> set(String id) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kSelectedNotebook, id);
    state = id;
  }
}

final selectedNotebookIdProvider =
    NotifierProvider<SelectedNotebookNotifier, String>(
        SelectedNotebookNotifier.new);

/// How the notes grid is laid out.
enum NoteViewMode { grid, column }

/// The grid layout mode (persisted, global). Toggled from the app bar.
class NoteViewModeNotifier extends Notifier<NoteViewMode> {
  @override
  NoteViewMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(AppConfig.kNoteViewMode) == 'column'
        ? NoteViewMode.column
        : NoteViewMode.grid;
  }

  Future<void> toggle() => set(
      state == NoteViewMode.grid ? NoteViewMode.column : NoteViewMode.grid);

  Future<void> set(NoteViewMode mode) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kNoteViewMode, mode.name);
    state = mode;
  }
}

final noteViewModeProvider =
    NotifierProvider<NoteViewModeNotifier, NoteViewMode>(
        NoteViewModeNotifier.new);

/// Which field the notes are ordered by. `custom` is the manual drag-reorder
/// order (the `position` column).
enum NoteSortField { custom, edited, created }

/// A sort selection: a [field] plus a direction. Drag-to-reorder is only
/// meaningful when [field] is [NoteSortField.custom].
class NoteSort {
  const NoteSort(this.field, this.ascending);

  final NoteSortField field;
  final bool ascending;
}

/// The active note sort (persisted, global). Picking a date field defaults to
/// descending (newest first); custom defaults to ascending (its defined order).
class NoteSortNotifier extends Notifier<NoteSort> {
  @override
  NoteSort build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final field = NoteSortField.values.firstWhere(
      (f) => f.name == prefs.getString(AppConfig.kNoteSortField),
      orElse: () => NoteSortField.custom,
    );
    final asc = prefs.getBool(AppConfig.kNoteSortAscending) ??
        (field == NoteSortField.custom);
    return NoteSort(field, asc);
  }

  /// Switch to [field], defaulting the direction sensibly (custom → ascending,
  /// dates → descending/newest-first).
  Future<void> setField(NoteSortField field) =>
      _store(NoteSort(field, field == NoteSortField.custom));

  Future<void> setAscending(bool ascending) =>
      _store(NoteSort(state.field, ascending));

  Future<void> _store(NoteSort sort) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kNoteSortField, sort.field.name);
    await prefs.setBool(AppConfig.kNoteSortAscending, sort.ascending);
    state = sort;
  }
}

final noteSortProvider =
    NotifierProvider<NoteSortNotifier, NoteSort>(NoteSortNotifier.new);

/// Orders [notes] by [sort], keeping pinned notes in a top section regardless
/// of direction. Returns a new list.
List<NoteRow> sortNotes(List<NoteRow> notes, NoteSort sort) {
  final list = [...notes];
  list.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1; // pinned always first
    final c = switch (sort.field) {
      NoteSortField.custom => a.position.compareTo(b.position),
      NoteSortField.edited => a.updated.compareTo(b.updated),
      NoteSortField.created => (a.created ?? '').compareTo(b.created ?? ''),
    };
    return sort.ascending ? c : -c;
  });
  return list;
}

/// The notebook actually shown in the grid: the user's selection when it still
/// exists, otherwise the default. Used to filter the active/archive/trash lists.
final activeNotebookIdProvider = Provider<String>((ref) {
  final selected = ref.watch(selectedNotebookIdProvider);
  final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
  final known = {for (final n in notebooks) n.id};
  if (selected.isNotEmpty && known.contains(selected)) return selected;
  return ref.watch(defaultNotebookIdProvider);
});

/// A snapshot of the notebook filtering inputs, resolved synchronously during a
/// provider build so the (later-running) stream `.map` closure stays pure.
class _NotebookFilter {
  const _NotebookFilter(this.selected, this.known, this.defaultId);

  final String selected;
  final Set<String> known;
  final String defaultId;

  List<NoteRow> apply(List<NoteRow> notes) => notes
      .where((n) => effectiveNotebookId(n, known, defaultId) == selected)
      .toList();
}

/// Resolves the current notebook filter. Watches its dependencies during build,
/// so the owning provider rebuilds whenever the selection or notebooks change.
_NotebookFilter _notebookFilter(Ref ref) {
  final selected = ref.watch(activeNotebookIdProvider);
  final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
  final known = {for (final n in notebooks) n.id};
  final defaultId = ref.watch(defaultNotebookIdProvider);
  return _NotebookFilter(selected, known, defaultId);
}

/// Active notes for the grid: filtered by the current search query and the
/// selected notebook.
final activeNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  final query = ref.watch(searchQueryProvider);
  final filter = _notebookFilter(ref);
  final sort = ref.watch(noteSortProvider);
  return ref
      .watch(notesRepositoryProvider)
      .searchActive(query)
      .map((notes) => sortNotes(filter.apply(notes), sort));
});

/// Archived notes stream, scoped to the selected notebook.
final archivedNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  final filter = _notebookFilter(ref);
  return ref.watch(notesRepositoryProvider).watchArchived().map(filter.apply);
});

/// Trashed (soft-deleted, not yet purged) notes stream, scoped to the selected
/// notebook.
final trashedNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  final filter = _notebookFilter(ref);
  return ref.watch(notesRepositoryProvider).watchTrash().map(filter.apply);
});

/// Checklist items for a given note.
final checklistItemsProvider =
    StreamProvider.family<List<ChecklistItemRow>, String>((ref, noteId) {
  return ref.watch(notesRepositoryProvider).watchItems(noteId);
});

/// A single note stream (for the editor).
final noteProvider = StreamProvider.family<NoteRow?, String>((ref, id) {
  return ref.watch(notesRepositoryProvider).watchNote(id);
});

/// Attachments for a given note.
final attachmentsProvider =
    StreamProvider.family<List<AttachmentRow>, String>((ref, noteId) {
  return ref.watch(notesRepositoryProvider).watchAttachments(noteId);
});

/// All of the user's (non-deleted) labels, ordered by name.
final labelsProvider = StreamProvider<List<LabelRow>>((ref) {
  return ref.watch(notesRepositoryProvider).watchLabels();
});

/// Active notes filtered to those carrying [labelId] (for the label view).
final notesByLabelProvider =
    StreamProvider.family<List<NoteRow>, String>((ref, labelId) {
  final repo = ref.watch(notesRepositoryProvider);
  return repo.watchActive().map((notes) =>
      notes.where((n) => labelIdsOf(n).contains(labelId)).toList());
});
