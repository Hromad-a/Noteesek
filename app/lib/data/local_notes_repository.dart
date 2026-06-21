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
          // No owner filter: the local-first grid shows every note on this
          // device regardless of owner (so account notes stay visible after
          // sign-out, and leftover data from any account is never hidden).
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
  Future<String> createNote({required String type, String notebook = ''}) async {
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
          notebook: Value(notebook),
          position: Value((maxPos ?? -1) + 1),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    return id;
  }

  @override
  Future<String> importNote(NoteImport data) async {
    final id = newPbId();
    await _db.transaction(() async {
      final maxPos = await (_db.selectOnly(_db.notes)
            ..addColumns([_db.notes.position.max()])
            ..where(_db.notes.owner.equals(_ownerId) &
                _db.notes.deleted.equals(false)))
          .map((r) => r.read(_db.notes.position.max()))
          .getSingleOrNull();
      final now = pbNow();

      await _db.into(_db.notes).insert(NotesCompanion.insert(
            id: id,
            owner: _ownerId,
            type: Value(data.type),
            title: Value(data.title),
            body: Value(data.body),
            pinned: Value(data.pinned),
            archived: Value(data.archived),
            color: Value(data.color),
            labels: Value(encodeLabelIds(data.labelIds)),
            notebook: Value(data.notebook),
            position: Value((maxPos ?? -1) + 1),
            created: Value(now),
            updated: Value(now),
            dirty: const Value(true),
          ));

      for (var i = 0; i < data.items.length; i++) {
        final item = data.items[i];
        await _db.into(_db.checklistItems).insert(
              ChecklistItemsCompanion.insert(
                id: newPbId(),
                note: id,
                content: Value(item.content),
                checked: Value(item.checked),
                position: Value(i),
                created: Value(now),
                updated: Value(now),
                dirty: const Value(true),
              ),
            );
      }

      for (final bytes in data.images) {
        await _db.into(_db.attachments).insert(AttachmentsCompanion.insert(
              id: newPbId(),
              note: id,
              data: Value(bytes),
              created: Value(now),
              updated: Value(now),
              dirty: const Value(true),
            ));
      }
    });
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
  Future<void> setColor(String id, String color) =>
      _patch(id, NotesCompanion(color: Value(color)));

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
  Future<void> convertNoteType(String id, String type) async {
    final note =
        await (_db.select(_db.notes)..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (note == null || note.type == type) return;
    final now = pbNow();

    await _db.transaction(() async {
      if (type == 'checklist') {
        // Text → checklist: each non-blank body line becomes an item.
        final lines = note.body
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        var pos = 0;
        for (final line in lines) {
          await _db.into(_db.checklistItems).insert(
                ChecklistItemsCompanion.insert(
                  id: newPbId(),
                  note: id,
                  content: Value(line),
                  position: Value(pos++),
                  created: Value(now),
                  updated: Value(now),
                  dirty: const Value(true),
                ),
              );
        }
        await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
          NotesCompanion(
            type: const Value('checklist'),
            body: const Value(''),
            updated: Value(now),
            dirty: const Value(true),
          ),
        );
      } else {
        // Checklist → text: items become body lines (order preserved), then are
        // tombstoned so their removal propagates on the next sync.
        final items = await (_db.select(_db.checklistItems)
              ..where((t) => t.note.equals(id) & t.deleted.equals(false))
              ..orderBy([(t) => OrderingTerm(expression: t.position)]))
            .get();
        final body = items
            .map((i) => i.content.trim())
            .where((c) => c.isNotEmpty)
            .join('\n');
        for (final it in items) {
          await (_db.update(_db.checklistItems)
                ..where((t) => t.id.equals(it.id)))
              .write(ChecklistItemsCompanion(
            deleted: const Value(true),
            updated: Value(now),
            dirty: const Value(true),
          ));
        }
        await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
          NotesCompanion(
            type: const Value('text'),
            body: Value(body),
            updated: Value(now),
            dirty: const Value(true),
          ),
        );
      }
    });
  }

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
    // Claim locally-created notebooks too so they sync up under the account.
    await (_db.update(_db.notebooks)
          ..where((t) => t.owner.equals(AppConfig.localOwner)))
        .write(NotebooksCompanion(
      owner: Value(userId),
      updated: Value(pbNow()),
      dirty: const Value(true),
    ));
    // …and locally-created labels. Without this they keep owner='local', which
    // fails the server's owner relation on push, so they'd never sync up.
    await (_db.update(_db.labels)
          ..where((t) => t.owner.equals(AppConfig.localOwner)))
        .write(LabelsCompanion(
      owner: Value(userId),
      updated: Value(pbNow()),
      dirty: const Value(true),
    ));
  }

  @override
  Future<bool> hasForeignAccountData(String userId) async {
    // True when the device holds non-deleted notes/notebooks owned by *another
    // account* (i.e. not this user and not the offline `local` sentinel). Used
    // at sign-in to decide whether to force the "wipe & load from server" flow
    // instead of the simple local-claim. Offline `local` data alone never
    // triggers it — it's just claimed into the account.
    final local = AppConfig.localOwner;
    final note = await (_db.select(_db.notes)
          ..where((t) =>
              t.owner.isNotValue(userId) &
              t.owner.isNotValue(local) &
              t.deleted.equals(false))
          ..limit(1))
        .get();
    if (note.isNotEmpty) return true;
    final nb = await (_db.select(_db.notebooks)
          ..where((t) =>
              t.owner.isNotValue(userId) &
              t.owner.isNotValue(local) &
              t.deleted.equals(false))
          ..limit(1))
        .get();
    return nb.isNotEmpty;
  }

  // ---- Labels ----

  @override
  Stream<List<LabelRow>> watchLabels() {
    return (_db.select(_db.labels)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.name.lower()),
          ]))
        .watch();
  }

  @override
  Future<String> createLabel(String name) async {
    final id = newPbId();
    final now = pbNow();
    await _db.into(_db.labels).insert(LabelsCompanion.insert(
          id: id,
          owner: _ownerId,
          name: Value(name.trim()),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    return id;
  }

  @override
  Future<void> renameLabel(String id, String name) async {
    await (_db.update(_db.labels)..where((t) => t.id.equals(id))).write(
      LabelsCompanion(
        name: Value(name.trim()),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> setLabelColor(String id, String color) async {
    await (_db.update(_db.labels)..where((t) => t.id.equals(id))).write(
      LabelsCompanion(
        color: Value(color),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> deleteLabel(String id) async {
    await _db.transaction(() async {
      await (_db.update(_db.labels)..where((t) => t.id.equals(id))).write(
        LabelsCompanion(
          deleted: const Value(true),
          updated: Value(pbNow()),
          dirty: const Value(true),
        ),
      );
      // Strip the id from every note that carries it.
      final notes = await _db.select(_db.notes).get();
      for (final n in notes) {
        final ids = labelIdsOfRaw(n.labels);
        if (ids.remove(id)) {
          await _patch(n.id, NotesCompanion(labels: Value(encodeLabelIds(ids))));
        }
      }
    });
  }

  @override
  Future<void> setNoteLabels(String noteId, List<String> labelIds) =>
      _patch(noteId, NotesCompanion(labels: Value(encodeLabelIds(labelIds))));

  // ---- Notebooks ----

  @override
  Stream<List<NotebookRow>> watchNotebooks() {
    return (_db.select(_db.notebooks)
          ..where((t) => t.deleted.equals(false))
          ..orderBy([
            (t) => OrderingTerm(expression: t.created), // oldest first
          ]))
        .watch();
  }

  @override
  Future<String> createNotebook(String name) async {
    final id = newPbId();
    final now = pbNow();
    await _db.into(_db.notebooks).insert(NotebooksCompanion.insert(
          id: id,
          owner: _ownerId,
          name: Value(name.trim()),
          created: Value(now),
          updated: Value(now),
          dirty: const Value(true),
        ));
    return id;
  }

  @override
  Future<void> renameNotebook(String id, String name) async {
    await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
      NotebooksCompanion(
        name: Value(name.trim()),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> setNotebookVisibility(String id, bool hidden) async {
    await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
      NotebooksCompanion(
        hiddenFromAll: Value(hidden),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> setNotebookSharedWith(String id, List<String> userIds) async {
    await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
      NotebooksCompanion(
        sharedWith: Value(encodeLabelIds(userIds)),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> setNoteLock(String id, String lockedBy, String lockedAt) async {
    await (_db.update(_db.notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        lockedBy: Value(lockedBy),
        lockedAt: Value(lockedAt),
        updated: Value(pbNow()),
        dirty: const Value(true),
      ),
    );
  }

  @override
  Future<void> deleteNotebook(String id,
      {required bool moveNotesToDefault}) async {
    final nb = await (_db.select(_db.notebooks)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (nb == null) return;

    await _db.transaction(() async {
      final notes = await (_db.select(_db.notes)
            ..where((t) => t.notebook.equals(id) & t.deleted.equals(false)))
          .get();
      for (final n in notes) {
        await _patch(
          n.id,
          moveNotesToDefault
              ? const NotesCompanion(notebook: Value('')) // → no notebook
              : const NotesCompanion(deleted: Value(true)),
        );
      }
      await (_db.update(_db.notebooks)..where((t) => t.id.equals(id))).write(
        NotebooksCompanion(
          deleted: const Value(true),
          updated: Value(pbNow()),
          dirty: const Value(true),
        ),
      );
    });
  }

  @override
  Future<void> setNoteNotebook(String noteId, String notebookId) =>
      _patch(noteId, NotesCompanion(notebook: Value(notebookId)));

  @override
  Future<void> claimNoteToNotebook(String noteId, String notebookId) => _patch(
      noteId,
      NotesCompanion(
        notebook: Value(notebookId),
        owner: Value(_ownerId),
      ));

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

  @override
  Future<void> reorderItems(List<String> orderedIds) async {
    await _db.transaction(() async {
      final now = pbNow();
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.checklistItems)
              ..where((t) => t.id.equals(orderedIds[i])))
            .write(ChecklistItemsCompanion(
          position: Value(i),
          updated: Value(now),
          dirty: const Value(true),
        ));
      }
    });
  }

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

  @override
  Stream<Set<String>> watchNoteIdsWithAttachments() {
    return (_db.selectOnly(_db.attachments, distinct: true)
          ..addColumns([_db.attachments.note])
          ..where(_db.attachments.deleted.equals(false)))
        .map((r) => r.read(_db.attachments.note)!)
        .watch()
        .map((ids) => ids.toSet());
  }
}
