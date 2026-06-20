import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'ids.dart';

part 'database.g.dart';

/// Local SQLite mirror (offline-first). Mirrors the PocketBase collections plus
/// per-row sync bookkeeping. See docs/sync-protocol.md.
///
/// Timestamps (`created`, `updated`) are stored as PocketBase-style ISO-8601
/// strings (e.g. "2026-06-05 00:14:58.581Z"). That format sorts
/// lexicographically in chronological order, so string comparison is a valid
/// last-write-wins comparison and a valid `filter=updated > "cursor"`.

@DataClassName('NoteRow')
class Notes extends Table {
  /// PocketBase record id (15 chars). Generated locally when created offline.
  TextColumn get id => text()();
  TextColumn get owner => text()();

  /// 'text' | 'checklist'
  TextColumn get type => text().withDefault(const Constant('text'))();
  TextColumn get title => text().withDefault(const Constant(''))();

  /// Body for text notes; empty for checklists (items live in [ChecklistItems]).
  TextColumn get body => text().withDefault(const Constant(''))();

  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();

  /// Background color key (see note_colors.dart). Empty = default surface.
  TextColumn get color => text().withDefault(const Constant(''))();

  /// Assigned label ids as a JSON array string (e.g. '["id1","id2"]').
  /// Membership rides this note's last-write-wins sync.
  TextColumn get labels => text().withDefault(const Constant('[]'))();

  /// The notebook this note belongs to ([Notebooks.id]). Empty or unknown means
  /// the default notebook. A note belongs to exactly one notebook.
  TextColumn get notebook => text().withDefault(const Constant(''))();

  /// Pessimistic edit lock for notes in shared notebooks (one editor at a time).
  /// [lockedBy] = the user id currently editing ('' = unlocked); [lockedAt] = ISO
  /// timestamp refreshed by the holder's heartbeat (a stale lock can be taken
  /// over). Empty for personal/private notes. Mirrors the server fields.
  TextColumn get lockedBy => text().withDefault(const Constant(''))();
  TextColumn get lockedAt => text().withDefault(const Constant(''))();

  /// Soft delete tombstone so removals propagate before being purged.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  TextColumn get created => text().nullable()();

  /// Last-known server `updated`; also bumped locally on edit. Sync cursor + LWW.
  TextColumn get updated => text().withDefault(const Constant(''))();

  /// True when the row has local changes not yet pushed to the server.
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  /// Manual sort order within the pinned/unpinned section. Lower = higher in list.
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ChecklistItemRow')
class ChecklistItems extends Table {
  TextColumn get id => text()();

  /// FK to [Notes.id].
  TextColumn get note => text()();

  /// The item label. Maps to the PocketBase `text` field (renamed here to avoid
  /// colliding with drift's built-in Table.text() builder).
  TextColumn get content => text().withDefault(const Constant(''))();
  BoolColumn get checked => boolean().withDefault(const Constant(false))();

  /// Sort order within the checklist.
  IntColumn get position => integer().withDefault(const Constant(0))();

  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get created => text().nullable()();
  TextColumn get updated => text().withDefault(const Constant(''))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AttachmentRow')
class Attachments extends Table {
  TextColumn get id => text()();

  /// FK to [Notes.id].
  TextColumn get note => text()();

  /// Server-side stored filename (within the attachments record). Empty until
  /// the local image has been uploaded.
  TextColumn get file => text().withDefault(const Constant(''))();

  /// The image bytes, kept locally so attachments render offline and on every
  /// platform (mobile + web). Populated on attach, and on pull after download.
  BlobColumn get data => blob().nullable()();

  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get created => text().nullable()();
  TextColumn get updated => text().withDefault(const Constant(''))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('LabelRow')
class Labels extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get name => text().withDefault(const Constant(''))();

  /// Color key for the label's chip (see note_colors.dart). Empty = no color.
  TextColumn get color => text().withDefault(const Constant(''))();

  /// Soft delete tombstone so removals propagate before being purged.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get created => text().nullable()();
  TextColumn get updated => text().withDefault(const Constant(''))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('NotebookRow')
class Notebooks extends Table {
  TextColumn get id => text()();
  TextColumn get owner => text()();
  TextColumn get name => text().withDefault(const Constant(''))();

  /// Users this notebook is shared with — a JSON id-array string (like
  /// `notes.labels`). Owner-managed; empty (`[]`) = private. Mirrors the server
  /// `notebooks.sharedWith` and rides the notebook's last-write-wins sync.
  TextColumn get sharedWith => text().withDefault(const Constant('[]'))();

  /// When true, this notebook's notes are excluded from the "All notes" view
  /// (they still show when the notebook is selected as the scope). Stored
  /// inverted (hidden, default false) so new/legacy rows default to visible.
  BoolColumn get hiddenFromAll =>
      boolean().withDefault(const Constant(false))();

  /// Soft delete tombstone so removals propagate before being purged.
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get created => text().nullable()();
  TextColumn get updated => text().withDefault(const Constant(''))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-collection pull cursor: the newest server `updated` seen on last pull.
class SyncCursors extends Table {
  TextColumn get collection => text()();
  TextColumn get lastSynced => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {collection};
}

@DriftDatabase(
    tables: [Notes, ChecklistItems, Attachments, Labels, Notebooks, SyncCursors])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ??
            driftDatabase(
              name: 'noteesek',
              // Required for web builds: assets live in web/ (see README).
              // Ignored on native platforms.
              web: DriftWebOptions(
                sqlite3Wasm: Uri.parse('sqlite3.wasm'),
                driftWorker: Uri.parse('drift_worker.js'),
              ),
            ));

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(attachments, attachments.data);
          }
          if (from < 3) {
            await m.addColumn(notes, notes.position);
          }
          if (from < 4) {
            await m.addColumn(notes, notes.color);
          }
          if (from < 5) {
            await m.addColumn(notes, notes.labels);
            await m.createTable(labels);
          }
          if (from < 6) {
            await m.addColumn(notes, notes.notebook);
            await m.createTable(notebooks);
          }
          if (from < 7) {
            await m.addColumn(labels, labels.color);
          }
          if (from < 8) {
            // Drop the default-notebook concept: move notes out of any default
            // notebook into "no notebook" (empty relation), soft-delete the
            // default notebooks (tombstone syncs), then drop the column. Raw SQL
            // because the `is_default` accessor no longer exists in the schema.
            final now = pbNow();
            await customStatement(
              "UPDATE notes SET notebook = '', dirty = 1, updated = ? "
              "WHERE notebook IN (SELECT id FROM notebooks WHERE is_default = 1)",
              [now],
            );
            await customStatement(
              "UPDATE notebooks SET deleted = 1, dirty = 1, updated = ? "
              "WHERE is_default = 1",
              [now],
            );
            await customStatement(
                'ALTER TABLE notebooks DROP COLUMN is_default');
          }
          if (from < 9) {
            await m.addColumn(notebooks, notebooks.hiddenFromAll);
          }
          if (from < 10) {
            // Shared notebooks: notebook membership + per-note edit lock.
            await m.addColumn(notebooks, notebooks.sharedWith);
            await m.addColumn(notes, notes.lockedBy);
            await m.addColumn(notes, notes.lockedAt);
          }
        },
      );

  /// Emits true whenever any local row across the content tables is still
  /// `dirty` (a change made on this device that hasn't been pushed to the
  /// server yet). Drives the "changes not synced" indicator. Mobile only —
  /// the web client has no local DB.
  Stream<bool> watchHasPending() {
    return customSelect(
      'SELECT EXISTS('
      '  SELECT 1 FROM notes WHERE dirty = 1'
      '  UNION ALL SELECT 1 FROM checklist_items WHERE dirty = 1'
      '  UNION ALL SELECT 1 FROM attachments WHERE dirty = 1'
      '  UNION ALL SELECT 1 FROM labels WHERE dirty = 1'
      '  UNION ALL SELECT 1 FROM notebooks WHERE dirty = 1'
      ') AS has_pending',
      readsFrom: {notes, checklistItems, attachments, labels, notebooks},
    ).watchSingle().map((row) => row.read<int>('has_pending') == 1);
  }

  /// Deletes ALL locally-stored data — notes, checklist items, attachments,
  /// labels and the sync cursors — resetting the device to a fresh-install
  /// state. Irreversible; used by the Settings "wipe data" action. Clearing the
  /// cursors means a subsequent sync (if a server is still connected) re-pulls
  /// from scratch rather than assuming the local mirror is current.
  Future<void> wipeAllLocal() async {
    await transaction(() async {
      await delete(checklistItems).go();
      await delete(attachments).go();
      await delete(notes).go();
      await delete(labels).go();
      await delete(notebooks).go();
      await delete(syncCursors).go();
    });
  }
}
