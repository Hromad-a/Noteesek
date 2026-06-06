import 'dart:convert';

import 'package:drift/drift.dart' show Uint8List;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  Future<String> createNote({required String type});
  Future<void> updateNoteFields(String id, {String? title, String? body});
  Future<void> setPinned(String id, bool pinned);
  Future<void> setArchived(String id, bool archived);
  Future<void> setColor(String id, String color);
  Future<void> softDelete(String id);
  Future<void> restore(String id);

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

/// Active notes stream for the grid, filtered by the current search query.
final activeNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  final query = ref.watch(searchQueryProvider);
  return ref.watch(notesRepositoryProvider).searchActive(query);
});

/// Archived notes stream.
final archivedNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  return ref.watch(notesRepositoryProvider).watchArchived();
});

/// Trashed (soft-deleted, not yet purged) notes stream.
final trashedNotesProvider = StreamProvider<List<NoteRow>>((ref) {
  return ref.watch(notesRepositoryProvider).watchTrash();
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
