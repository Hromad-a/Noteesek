import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:noteesek/data/local/database.dart';

/// Exercises the v7 → v8 drift migration that removes the default-notebook
/// concept: notes in a default notebook are un-categorized, the default
/// notebook is soft-deleted, and the `is_default` column is dropped.
void main() {
  test('v7 → v8 migration empties + tombstones the default notebook', () async {
    final raw = sqlite3.openInMemory();
    // Minimal v7 schema (only the columns the from<8 migration touches).
    raw.execute('''
      CREATE TABLE notebooks (
        id TEXT PRIMARY KEY, owner TEXT, name TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        created TEXT, updated TEXT NOT NULL DEFAULT '',
        dirty INTEGER NOT NULL DEFAULT 0);
    ''');
    raw.execute('''
      CREATE TABLE notes (
        id TEXT PRIMARY KEY, notebook TEXT NOT NULL DEFAULT '',
        deleted INTEGER NOT NULL DEFAULT 0,
        updated TEXT NOT NULL DEFAULT '',
        dirty INTEGER NOT NULL DEFAULT 0);
    ''');
    raw.execute('PRAGMA user_version = 7');

    raw.execute(
        "INSERT INTO notebooks (id, owner, name, is_default) "
        "VALUES ('def', 'u1', 'Notebook', 1)");
    raw.execute(
        "INSERT INTO notebooks (id, owner, name, is_default) "
        "VALUES ('work', 'u1', 'Work', 0)");
    raw.execute("INSERT INTO notes (id, notebook) VALUES ('n1', 'def')");
    raw.execute("INSERT INTO notes (id, notebook) VALUES ('n2', 'work')");

    // Opening AppDatabase on the pre-seeded handle runs onUpgrade(7 → 8).
    final db = AppDatabase(NativeDatabase.opened(raw));
    await db.customSelect('SELECT 1').get(); // force migration to run

    expect(raw.select('PRAGMA user_version').first.values.first, 8);

    // The is_default column is gone.
    final cols = raw
        .select('PRAGMA table_info(notebooks)')
        .map((r) => r['name'] as String);
    expect(cols, isNot(contains('is_default')));

    // The default notebook's note is now uncategorized; the other is untouched.
    final n1 = raw.select("SELECT notebook FROM notes WHERE id = 'n1'").first;
    final n2 = raw.select("SELECT notebook FROM notes WHERE id = 'n2'").first;
    expect(n1['notebook'], '');
    expect(n2['notebook'], 'work');

    // The default notebook is soft-deleted + dirty (tombstone syncs).
    final def = raw.select("SELECT deleted, dirty FROM notebooks WHERE id = 'def'").first;
    expect(def['deleted'], 1);
    expect(def['dirty'], 1);

    await db.close();
  });
}
