/// <reference path="../pb_data/types.d.ts" />

// Shared-notebook edit lock, as its own record (one row per locked note) with a
// UNIQUE constraint on `note`. The uniqueness makes acquisition atomic: two
// members opening the same note race to *create* the lock row and exactly one
// create succeeds — the other gets a validation error and knows it didn't win.
// No duelling, server-arbitrated. Decoupled from the note record so lock writes
// never touch note content / its `updated` (no clobbering, no sync interference).
//
// Lifecycle (client, all direct to the server — shared editing is online-only):
//   acquire   = create {note, lockedBy: me, lockedAt: now}
//   heartbeat = update lockedAt
//   release   = delete the row
// Readers subscribe via realtime for instant lock visibility; a row whose
// lockedAt is older than the client's expiry window is treated as stale (a
// crashed holder) and may be deleted + re-taken.
//
// Access: any member of the note's notebook (same predicate as notes). The
// `note` relation cascade-deletes the lock if the note is hard-deleted.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const notes = app.findCollectionByNameOrId("notes");

  const member =
    "@request.auth.id != '' && (" +
    "note.owner = @request.auth.id" +
    " || note.notebook.owner = @request.auth.id" +
    " || note.notebook.sharedWith.id ?= @request.auth.id)";

  const collection = new Collection({
    type: "base",
    name: "note_locks",
    listRule: member,
    viewRule: member,
    createRule: member,
    updateRule: member,
    deleteRule: member,
    fields: [
      {
        type: "relation",
        name: "note",
        required: true,
        maxSelect: 1,
        collectionId: notes.id,
        cascadeDelete: true,
      },
      {
        type: "relation",
        name: "lockedBy",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: false,
      },
      {
        type: "text",
        name: "lockedAt",
        max: 40,
      },
      {
        type: "autodate",
        name: "created",
        onCreate: true,
      },
      {
        type: "autodate",
        name: "updated",
        onCreate: true,
        onUpdate: true,
      },
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_note_locks_note ON note_locks (note)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("note_locks");
  app.delete(collection);
});
