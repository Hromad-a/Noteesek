import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

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

/// Per-collection pull cursor: the newest server `updated` seen on last pull.
class SyncCursors extends Table {
  TextColumn get collection => text()();
  TextColumn get lastSynced => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {collection};
}

@DriftDatabase(tables: [Notes, ChecklistItems, Attachments, SyncCursors])
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
  int get schemaVersion => 3;

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
        },
      );
}
