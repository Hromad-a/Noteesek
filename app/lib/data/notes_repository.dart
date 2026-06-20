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

/// The notebook selector scope shown in the grid. A scope is either of these two
/// sentinels or a concrete notebook id.
///
/// - [kAllNotes] (the default): every note, regardless of notebook.
/// - [kNoNotebook]: only uncategorized notes — those whose [NoteRow.notebook] is
///   empty or points at a deleted/unknown notebook.
const String kAllNotes = '';
const String kNoNotebook = '__no_notebook__';

/// Whether [note] belongs to the given selector [scope]. A note counts as "in a
/// notebook" only when its [NoteRow.notebook] is non-empty and present in
/// [knownNotebookIds]; otherwise it is uncategorized ("no notebook").
bool noteInScope(NoteRow note, String scope, Set<String> knownNotebookIds,
    {Set<String> hiddenNotebookIds = const {}}) {
  if (scope == kAllNotes) {
    // Uncategorized notes (and notes in a deleted/unknown notebook) always show;
    // notes in a notebook flagged "hidden from All notes" are excluded.
    return note.notebook.isEmpty ||
        !hiddenNotebookIds.contains(note.notebook);
  }
  final inNotebook =
      note.notebook.isNotEmpty && knownNotebookIds.contains(note.notebook);
  if (scope == kNoNotebook) return !inNotebook;
  return inNotebook && note.notebook == scope;
}

/// A checklist item to create as part of an imported note.
class ImportedItem {
  const ImportedItem(this.content, this.checked);
  final String content;
  final bool checked;
}

/// A fully-resolved note to create in one shot via [NotesRepository.importNote].
/// Labels and notebook are already resolved to ids by the import service (so the
/// repo just writes them); images are raw attachment bytes.
class NoteImport {
  const NoteImport({
    required this.type,
    this.title = '',
    this.body = '',
    this.pinned = false,
    this.archived = false,
    this.color = '',
    this.labelIds = const [],
    this.notebook = '',
    this.items = const [],
    this.images = const [],
  });

  final String type; // 'text' | 'checklist'
  final String title;
  final String body;
  final bool pinned;
  final bool archived;
  final String color;
  final List<String> labelIds;
  final String notebook; // notebook id ('' = default)
  final List<ImportedItem> items;
  final List<Uint8List> images;
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

  /// Create a fully-populated note (with checklist items and image attachments)
  /// in one shot. Used by the import flows. Returns the new note id.
  Future<String> importNote(NoteImport data);

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

  /// True if the local DB holds non-deleted notes/notebooks owned by *another
  /// account* — i.e. not [userId] and not the offline `local` sentinel. Drives
  /// the sign-in flow: offline `local` data alone is just claimed, but another
  /// account's data forces the "wipe & load from server" choice. Always false
  /// on web (no local DB).
  Future<bool> hasForeignAccountData(String userId);

  // Labels
  Stream<List<LabelRow>> watchLabels();
  Future<String> createLabel(String name);
  Future<void> renameLabel(String id, String name);

  /// Set a label's color key (see note_colors.dart; '' = no color).
  Future<void> setLabelColor(String id, String color);

  /// Soft-delete a label and remove its id from every note that carries it.
  Future<void> deleteLabel(String id);

  /// Replace a note's assigned labels with [labelIds].
  Future<void> setNoteLabels(String noteId, List<String> labelIds);

  // Notebooks
  Stream<List<NotebookRow>> watchNotebooks();

  Future<String> createNotebook(String name);
  Future<void> renameNotebook(String id, String name);

  /// Set whether this notebook's notes are hidden from the "All notes" view.
  Future<void> setNotebookVisibility(String id, bool hidden);

  /// Replace the set of users this notebook is shared with (owner-only; the
  /// server enforces that). [userIds] is the full member list, not a delta.
  /// Server-connected only — no-op semantics offline are the caller's concern.
  Future<void> setNotebookSharedWith(String id, List<String> userIds);

  /// Set the per-note edit lock (shared notebooks, pessimistic concurrency).
  /// [lockedBy] = the holder's user id ('' to release); [lockedAt] = ISO
  /// timestamp ('' to clear). Used for acquire / heartbeat / release.
  Future<void> setNoteLock(String id, String lockedBy, String lockedAt);

  /// Soft-delete a notebook. Its notes are either reassigned to "no notebook"
  /// ([moveNotesToDefault] = true) or soft-deleted to Trash.
  Future<void> deleteNotebook(String id, {required bool moveNotesToDefault});

  /// Move a note into [notebookId] (empty string = no notebook).
  Future<void> setNoteNotebook(String noteId, String notebookId);

  // Checklist items
  Stream<List<ChecklistItemRow>> watchItems(String noteId);
  Future<String> addItem(String noteId, {String content});
  Future<void> setItemContent(String id, String content);
  Future<void> setItemChecked(String id, bool checked);
  Future<void> deleteItem(String id);

  /// Reassign positions so [orderedIds] is sorted 0…n within a note's checklist.
  Future<void> reorderItems(List<String> orderedIds);

  // Attachments
  Stream<List<AttachmentRow>> watchAttachments(String noteId);
  Future<String> addAttachment(String noteId, Uint8List bytes);
  Future<void> deleteAttachment(String id);

  /// The ids of notes that currently have at least one (non-deleted)
  /// attachment. Drives the "has image" search filter.
  Stream<Set<String>> watchNoteIdsWithAttachments();
}

/// Selects the implementation by platform: web talks directly to the server,
/// mobile uses the local-first drift store.
final notesRepositoryProvider = Provider<NotesRepository>((ref) {
  if (kIsWeb) {
    final pb = ref.watch(pocketBaseProvider);
    // Rebuild (fresh, empty cache) whenever the signed-in account changes — the
    // PocketBase client is stable across logins, so without this the repo would
    // keep serving the previous session's notes until a hard refresh.
    ref.watch(authUserIdProvider);
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

/// Active filters layered on top of the notes grid (session-only — reset on
/// app launch). [labelIds] match by OR; [color]/[type] are exact; [hasImage]
/// keeps only notes with an attachment. [notebookId] overrides the grid's
/// notebook scope: `null` = inherit the selected notebook, `''` = all
/// notebooks, otherwise a specific notebook id.
class SearchFilters {
  const SearchFilters({
    this.labelIds = const {},
    this.color,
    this.type,
    this.hasImage = false,
    this.notebookId,
  });

  final Set<String> labelIds;
  final String? color;
  final String? type;
  final bool hasImage;
  final String? notebookId;

  /// All-notebooks sentinel for [notebookId].
  static const String allNotebooks = '';

  bool get isActive =>
      labelIds.isNotEmpty ||
      color != null ||
      type != null ||
      hasImage ||
      notebookId != null;

  int get count =>
      (labelIds.isNotEmpty ? 1 : 0) +
      (color != null ? 1 : 0) +
      (type != null ? 1 : 0) +
      (hasImage ? 1 : 0) +
      (notebookId != null ? 1 : 0);
}

class SearchFiltersNotifier extends Notifier<SearchFilters> {
  @override
  SearchFilters build() => const SearchFilters();

  void toggleLabel(String id) {
    final next = {...state.labelIds};
    next.contains(id) ? next.remove(id) : next.add(id);
    state = SearchFilters(
      labelIds: next,
      color: state.color,
      type: state.type,
      hasImage: state.hasImage,
      notebookId: state.notebookId,
    );
  }

  void setColor(String? color) => state = SearchFilters(
        labelIds: state.labelIds,
        color: color,
        type: state.type,
        hasImage: state.hasImage,
        notebookId: state.notebookId,
      );

  void setType(String? type) => state = SearchFilters(
        labelIds: state.labelIds,
        color: state.color,
        type: type,
        hasImage: state.hasImage,
        notebookId: state.notebookId,
      );

  void setHasImage(bool hasImage) => state = SearchFilters(
        labelIds: state.labelIds,
        color: state.color,
        type: state.type,
        hasImage: hasImage,
        notebookId: state.notebookId,
      );

  void setNotebook(String? notebookId) => state = SearchFilters(
        labelIds: state.labelIds,
        color: state.color,
        type: state.type,
        hasImage: state.hasImage,
        notebookId: notebookId,
      );

  void clear() => state = const SearchFilters();
}

final searchFiltersProvider =
    NotifierProvider<SearchFiltersNotifier, SearchFilters>(
        SearchFiltersNotifier.new);

/// The ids of notes that currently carry at least one (non-deleted)
/// attachment, for the "has image" filter.
final noteIdsWithAttachmentsProvider = StreamProvider<Set<String>>((ref) {
  return ref.watch(notesRepositoryProvider).watchNoteIdsWithAttachments();
});

/// Applies the non-notebook [SearchFilters] to [notes]. Notebook scoping is
/// handled separately (in [activeNotesProvider]) since it interacts with the
/// grid's selection.
List<NoteRow> applySearchFilters(
    List<NoteRow> notes, SearchFilters f, Set<String> noteIdsWithImages) {
  if (f.labelIds.isEmpty &&
      f.color == null &&
      f.type == null &&
      !f.hasImage) {
    return notes;
  }
  return notes.where((n) {
    if (f.labelIds.isNotEmpty) {
      final ids = labelIdsOf(n).toSet();
      if (!f.labelIds.any(ids.contains)) return false;
    }
    if (f.color != null && n.color != f.color) return false;
    if (f.type != null && n.type != f.type) return false;
    if (f.hasImage && !noteIdsWithImages.contains(n.id)) return false;
    return true;
  }).toList();
}

/// All of the user's (non-deleted) notebooks, ordered oldest-first.
final notebooksProvider = StreamProvider<List<NotebookRow>>((ref) {
  return ref.watch(notesRepositoryProvider).watchNotebooks();
});

/// The selector scope the user last chose (persisted): [kAllNotes] (default),
/// [kNoNotebook], or a notebook id.
class SelectedNotebookNotifier extends Notifier<String> {
  @override
  String build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(AppConfig.kSelectedNotebook) ?? kAllNotes;
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

/// Notebook ids the user has personally hidden from "All notes" — a local,
/// per-user preference (persisted). Distinct from a notebook's global
/// `hiddenFromAll` (owner-only): a *member* of a shared notebook can't write the
/// owner's flag, so they hide it locally with this instead. Both are merged in
/// [_notebookFilter].
class LocallyHiddenNotebooksNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return labelIdsOfRaw(
            prefs.getString(AppConfig.kLocallyHiddenNotebooks) ?? '[]')
        .toSet();
  }

  Future<void> toggle(String id) async {
    final next = {...state};
    next.contains(id) ? next.remove(id) : next.add(id);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(
        AppConfig.kLocallyHiddenNotebooks, encodeLabelIds(next.toList()));
    state = next;
  }
}

final locallyHiddenNotebooksProvider =
    NotifierProvider<LocallyHiddenNotebooksNotifier, Set<String>>(
        LocallyHiddenNotebooksNotifier.new);

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

/// Whether checked checklist items auto-sink to a collapsible "completed"
/// section at the bottom of the editor (persisted, global). Off = keep manual
/// order regardless of checked state.
class ChecklistAutoSortNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(AppConfig.kChecklistAutoSort) ?? false;
  }

  Future<void> set(bool value) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(AppConfig.kChecklistAutoSort, value);
    state = value;
  }
}

final checklistAutoSortProvider =
    NotifierProvider<ChecklistAutoSortNotifier, bool>(
        ChecklistAutoSortNotifier.new);

/// Whether note bodies render as Markdown (and the editor shows a formatting
/// toolbar). Persisted, global. Off by default.
class MarkdownEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(AppConfig.kMarkdownEnabled) ?? false;
  }

  Future<void> set(bool value) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(AppConfig.kMarkdownEnabled, value);
    state = value;
  }
}

final markdownEnabledProvider =
    NotifierProvider<MarkdownEnabledNotifier, bool>(
        MarkdownEnabledNotifier.new);

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

/// The scope actually shown in the grid: the user's selection when it's still a
/// valid scope ([kAllNotes], [kNoNotebook], or an existing notebook id),
/// otherwise [kAllNotes]. A stale id (e.g. the removed default notebook)
/// collapses to "All notes". Used to filter the active/archive/trash lists.
final activeNotebookIdProvider = Provider<String>((ref) {
  final selected = ref.watch(selectedNotebookIdProvider);
  if (selected == kAllNotes || selected == kNoNotebook) return selected;
  final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
  final known = {for (final n in notebooks) n.id};
  return known.contains(selected) ? selected : kAllNotes;
});

/// A snapshot of the notebook filtering inputs, resolved synchronously during a
/// provider build so the (later-running) stream `.map` closure stays pure.
class _NotebookFilter {
  const _NotebookFilter(this.scope, this.known, this.hidden);

  final String scope;
  final Set<String> known;
  final Set<String> hidden;

  List<NoteRow> apply(List<NoteRow> notes) => notes
      .where((n) =>
          noteInScope(n, scope, known, hiddenNotebookIds: hidden))
      .toList();
}

/// Resolves the current notebook filter. Watches its dependencies during build,
/// so the owning provider rebuilds whenever the selection or notebooks change.
_NotebookFilter _notebookFilter(Ref ref) {
  final scope = ref.watch(activeNotebookIdProvider);
  final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
  final known = {for (final n in notebooks) n.id};
  // A notebook is hidden from "All notes" by its owner's global flag OR by this
  // user's local preference (the latter is how a shared-notebook member hides it).
  final hidden = {
    for (final n in notebooks)
      if (n.hiddenFromAll) n.id,
    ...ref.watch(locallyHiddenNotebooksProvider),
  };
  return _NotebookFilter(scope, known, hidden);
}

/// Active notes for the grid: filtered by the current search query, the
/// notebook scope (or a filter override), the active [SearchFilters], then
/// sorted.
final activeNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  final query = ref.watch(searchQueryProvider);
  final nbFilter = _notebookFilter(ref);
  final sort = ref.watch(noteSortProvider);
  final filters = ref.watch(searchFiltersProvider);
  final imageIds =
      ref.watch(noteIdsWithAttachmentsProvider).asData?.value ?? const {};

  List<NoteRow> scopeNotebook(List<NoteRow> notes) {
    return switch (filters.notebookId) {
      null => nbFilter.apply(notes), // inherit the grid's selected scope
      SearchFilters.allNotebooks => notes, // all notebooks
      final scope =>
        notes.where((n) => noteInScope(n, scope, nbFilter.known)).toList(),
    };
  }

  return ref.watch(notesRepositoryProvider).searchActive(query).map((notes) {
    final scoped = scopeNotebook(notes);
    final filtered = applySearchFilters(scoped, filters, imageIds);
    return sortNotes(filtered, sort);
  });
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
