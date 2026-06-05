import 'package:drift/drift.dart';

import '../config/app_config.dart';
import 'local/database.dart';
import 'local/ids.dart';
import 'notes_repository.dart';

/// Offline-first [NotesRepository] backed by the local drift database (mobile).
/// Every mutation marks the row `dirty` and bumps `updated` so the sync engine
/// later pushes it. Nothing here touches the network.
class LocalNotesRepository implements NotesRepository {
  LocalNotesRepository(this._db, this._ownerId);

  final AppDatabase _db;
  final String _ownerId;

  // ---- Notes: queries ----

  @override
  Stream<List<NoteRow>> watchActive() {
    return (_db.select(_db.notes)
          ..where((t) => t.deleted.equals(false) & t.archived.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.position, mode: OrderingMode.asc),
          ]))
        .watch();
  }

  @override
  Stream<List<NoteRow>> watchArchived() {
    return (_db.select(_db.notes)
          ..where((t) => t.deleted.equals(false) & t.archived.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updated, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  @override
  Stream<NoteRow?> watchNote(String id) {
    return (_db.select(_db.notes)..where((t) => t.id.equals(id)))
        .watchSingleOrNull();
  }

  @override
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
            (t) => OrderingTerm(expression: t.position, mode: OrderingMode.asc),
          ]))
        .watch();
  }

  // ---- Notes: mutations ----

  @override
  Future<String> createNote({required String type}) async {
    final maxPos = await (_db.selectOnly(_db.notes)
          ..addColumns([_db.notes.position.max()])
          ..where(_db.notes.owner.equals(_ownerId) &
              _db.notes.deleted.equals(false)))
        .map((r) => r.read(_db.notes.position.max()))
        .getSingleOrNull();

    final id = newPbId();
    final now = pbNow();
    await _db.into(_db.notes).insert(NotesCompanion.insert(
          id: id,
          owner: _ownerId,
          type: Value(type),
          position: Value((maxPos ?? -1) + 1),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    return id;
  }

  @override
  Future<void> updateNoteFields(String id, {String? title, String? body}) async {
    await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        title: title == null ? const Value.absent() : Value(title),
        body: body == null ? const Value.absent() : Value(body),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> setPinned(String id, bool pinned) =>
      _patch(id, NotesCompanion(pinned: Value(pinned)));

  @override
  Future<void> setArchived(String id, bool archived) =>
      _patch(id, NotesCompanion(archived: Value(archived)));

  @override
  Future<void> softDelete(String id) =>
      _patch(id, const NotesCompanion(deleted: Value(true)));

  @override
  Stream<List<NoteRow>> watchTrash() {
    return (_db.select(_db.notes)
          ..where((t) => t.deleted.equals(true))
          ..orderBy([
            (t) => OrderingTerm(expression: t.updated, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  @override
  Future<void> restore(String id) =>
      _patch(id, const NotesCompanion(deleted: Value(false)));

  @override
  Future<void> reorderNotes(List<String> orderedIds) async {
    await _db.transaction(() async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.notes)
              ..where((t) => t.id.equals(orderedIds[i])))
            .write(NotesCompanion(
          position: Value(i),
          updated: Value(pbNow()),
          dirty: const Value(true),
        ));
      }
    });
  }

  /// Permanently remove a trashed note and its children from the local DB.
  /// (On mobile the caller also hard-deletes the server record via the sync
  /// engine.)
  @override
  Future<void> deleteForever(String noteId) async {
    await _db.transaction(() async {
      await (_db.delete(_db.checklistItems)
            ..where((t) => t.note.equals(noteId)))
          .go();
      await (_db.delete(_db.attachments)..where((t) => t.note.equals(noteId)))
          .go();
      await (_db.delete(_db.notes)..where((t) => t.id.equals(noteId))).go();
    });
  }

  @override
  Future<List<String>> trashedNoteIds() =>
      (_db.select(_db.notes)..where((t) => t.deleted.equals(true)))
          .map((r) => r.id)
          .get();

  Future<void> _patch(String id, NotesCompanion patch) async {
    await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
      patch.copyWith(updated: Value(pbNow()), dirty: const Value(true)),
    );
  }

  @override
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

  @override
  Stream<List<ChecklistItemRow>> watchItems(String noteId) {
    return (_db.select(_db.checklistItems)
          ..where((t) => t.note.equals(noteId) & t.deleted.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.position),
          ]))
        .watch();
  }

  @override
  Future<String> addItem(String noteId, {String content = ''}) async {
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
    await _patch(noteId, const NotesCompanion()); // touch parent
    return id;
  }

  @override
  Future<void> setItemContent(String id, String content) =>
      _patchItem(id, ChecklistItemsCompanion(content: Value(content)));

  @override
  Future<void> setItemChecked(String id, bool checked) =>
      _patchItem(id, ChecklistItemsCompanion(checked: Value(checked)));

  @override
  Future<void> deleteItem(String id) =>
      _patchItem(id, const ChecklistItemsCompanion(deleted: Value(true)));

  Future<void> _patchItem(String id, ChecklistItemsCompanion patch) async {
    await (_db.update(_db.checklistItems)..where((t) => t.id.equals(id))).write(
      patch.copyWith(updated: Value(pbNow()), dirty: const Value(true)),
    );
  }

  // ---- Attachments ----

  @override
  Stream<List<AttachmentRow>> watchAttachments(String noteId) {
    return (_db.select(_db.attachments)
          ..where((t) => t.note.equals(noteId) & t.deleted.equals(false))
          ..orderBy([(t) => OrderingTerm(expression: t.created)]))
        .watch();
  }

  @override
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

  @override
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
