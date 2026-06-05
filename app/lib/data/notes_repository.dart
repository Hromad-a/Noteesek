import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../providers.dart';
import 'local/database.dart';
import 'local/ids.dart';

/// All note reads/writes go through the local drift database (offline-first).
/// Every mutation marks the row `dirty` and bumps `updated`, so the sync engine
/// later pushes it. Nothing here touches the network.
class NotesRepository {
  NotesRepository(this._db, this._ownerId);

  final AppDatabase _db;
  final String _ownerId;

  // ---- Notes: queries ----

  /// Active notes (not archived, not deleted), pinned first then newest.
  Stream<List<NoteRow>> watchActive() {
    return (_db.select(_db.notes)
          ..where((t) => t.deleted.equals(false) & t.archived.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updated, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Archived notes (not deleted), newest first.
  Stream<List<NoteRow>> watchArchived() {
    return (_db.select(_db.notes)
          ..where((t) => t.deleted.equals(false) & t.archived.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updated, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Stream<NoteRow?> watchNote(String id) {
    return (_db.select(_db.notes)..where((t) => t.id.equals(id)))
        .watchSingleOrNull();
  }

  /// Offline search over active notes: matches the title, body, or any of the
  /// note's checklist items (case-insensitive substring). Empty query returns
  /// the normal active list.
  Stream<List<NoteRow>> searchActive(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) return watchActive();
    final pattern = '%$q%';

    final itemMatch = existsQuery(
      _db.select(_db.checklistItems)
        ..where((i) =>
            i.note.equalsExp(_db.notes.id) &
            i.deleted.equals(false) &
            i.content.lower().like(pattern)),
    );

    return (_db.select(_db.notes)
          ..where((t) =>
              t.deleted.equals(false) &
              t.archived.equals(false) &
              (t.title.lower().like(pattern) |
                  t.body.lower().like(pattern) |
                  itemMatch))
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.updated, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  // ---- Notes: mutations ----

  Future<String> createNote({required String type}) async {
    final id = newPbId();
    final now = pbNow();
    await _db.into(_db.notes).insert(NotesCompanion.insert(
          id: id,
          owner: _ownerId,
          type: Value(type),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    return id;
  }

  Future<void> updateNoteFields(
    String id, {
    String? title,
    String? body,
  }) async {
    await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        title: title == null ? const Value.absent() : Value(title),
        body: body == null ? const Value.absent() : Value(body),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  Future<void> setPinned(String id, bool pinned) =>
      _patch(id, NotesCompanion(pinned: Value(pinned)));

  Future<void> setArchived(String id, bool archived) =>
      _patch(id, NotesCompanion(archived: Value(archived)));

  /// Move to trash: a soft-delete tombstone that propagates during sync.
  Future<void> softDelete(String id) =>
      _patch(id, const NotesCompanion(deleted: Value(true)));

  /// Trash = soft-deleted, not yet purged. Newest first.
  Stream<List<NoteRow>> watchTrash() {
    return (_db.select(_db.notes)
          ..where((t) => t.deleted.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updated, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  /// Restore a trashed note back to the active list.
  Future<void> restore(String id) =>
      _patch(id, const NotesCompanion(deleted: Value(false)));

  /// Permanently remove a trashed note and its children from the local DB.
  /// Returns the ids so the caller can also hard-delete them on the server.
  Future<List<String>> purgeLocal(String noteId) async {
    final itemIds = await (_db.select(_db.checklistItems)
          ..where((t) => t.note.equals(noteId)))
        .map((r) => r.id)
        .get();
    final attIds = await (_db.select(_db.attachments)
          ..where((t) => t.note.equals(noteId)))
        .map((r) => r.id)
        .get();
    await _db.transaction(() async {
      await (_db.delete(_db.checklistItems)
            ..where((t) => t.note.equals(noteId)))
          .go();
      await (_db.delete(_db.attachments)..where((t) => t.note.equals(noteId)))
          .go();
      await (_db.delete(_db.notes)..where((t) => t.id.equals(noteId))).go();
    });
    return [noteId, ...itemIds, ...attIds];
  }

  Future<List<String>> trashedNoteIds() =>
      (_db.select(_db.notes)..where((t) => t.deleted.equals(true)))
          .map((r) => r.id)
          .get();

  Future<void> _patch(String id, NotesCompanion patch) async {
    await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
      patch.copyWith(updated: Value(pbNow()), dirty: const Value(true)),
    );
  }

  /// Reassign locally-owned notes to [userId] so they upload on the next sync.
  /// Called when connecting a server for the first time. Child rows
  /// (checklist items, attachments) created offline are already dirty.
  Future<void> claimLocalNotes(String userId) async {
    await (_db.update(_db.notes)
          ..where((t) => t.owner.equals(AppConfig.localOwner)))
        .write(NotesCompanion(
      owner: Value(userId),
      updated: Value(pbNow()),
      dirty: const Value(true),
    ));
  }

  // ---- Checklist items ----

  Stream<List<ChecklistItemRow>> watchItems(String noteId) {
    return (_db.select(_db.checklistItems)
          ..where((t) => t.note.equals(noteId) & t.deleted.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.position),
          ]))
        .watch();
  }

  Future<String> addItem(String noteId, {String content = ''}) async {
    // Append at the end.
    final maxPos = await (_db.selectOnly(_db.checklistItems)
          ..addColumns([_db.checklistItems.position.max()])
          ..where(_db.checklistItems.note.equals(noteId) &
              _db.checklistItems.deleted.equals(false)))
        .map((r) => r.read(_db.checklistItems.position.max()))
        .getSingleOrNull();

    final id = newPbId();
    final now = pbNow();
    await _db.into(_db.checklistItems).insert(ChecklistItemsCompanion.insert(
          id: id,
          note: noteId,
          content: Value(content),
          position: Value((maxPos ?? -1) + 1),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    // Touch parent so it surfaces and syncs.
    await _patch(noteId, const NotesCompanion());
    return id;
  }

  Future<void> setItemContent(String id, String content) =>
      _patchItem(id, ChecklistItemsCompanion(content: Value(content)));

  Future<void> setItemChecked(String id, bool checked) =>
      _patchItem(id, ChecklistItemsCompanion(checked: Value(checked)));

  Future<void> deleteItem(String id) =>
      _patchItem(id, const ChecklistItemsCompanion(deleted: Value(true)));

  Future<void> _patchItem(String id, ChecklistItemsCompanion patch) async {
    await (_db.update(_db.checklistItems)..where((t) => t.id.equals(id))).write(
      patch.copyWith(updated: Value(pbNow()), dirty: const Value(true)),
    );
  }

  // ---- Attachments ----

  Stream<List<AttachmentRow>> watchAttachments(String noteId) {
    return (_db.select(_db.attachments)
          ..where((t) => t.note.equals(noteId) & t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm(expression: t.created)]))
        .watch();
  }

  /// Attach an image. Bytes are stored locally so it renders immediately and
  /// offline; the sync engine uploads it to PocketBase file storage later.
  Future<String> addAttachment(String noteId, Uint8List bytes) async {
    final id = newPbId();
    final now = pbNow();
    await _db.into(_db.attachments).insert(AttachmentsCompanion.insert(
          id: id,
          note: noteId,
          data: Value(bytes),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    await _patch(noteId, const NotesCompanion()); // touch parent
    return id;
  }

  Future<void> deleteAttachment(String id) async {
    await (_db.update(_db.attachments)..where((t) => t.id.equals(id))).write(
      AttachmentsCompanion(
        deleted: const Value(true),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }
}

/// Provides a [NotesRepository] bound to the current active owner — the local
/// sentinel when not connected, or the account's user id once connected.
final notesRepositoryProvider = Provider<NotesRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final owner = ref.watch(activeOwnerProvider);
  return NotesRepository(db, owner);
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
final noteProvider =
    StreamProvider.family<NoteRow?, String>((ref, id) {
  return ref.watch(notesRepositoryProvider).watchNote(id);
});

/// Attachments for a given note.
final attachmentsProvider =
    StreamProvider.family<List<AttachmentRow>, String>((ref, noteId) {
  return ref.watch(notesRepositoryProvider).watchAttachments(noteId);
});
