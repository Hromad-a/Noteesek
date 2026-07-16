/// <reference path="../pb_data/types.d.ts" />

// Shared-notebook activity feed ("someone changed something").
//
// Three collections:
//   notebook_activity — the shared, append-only feed. One row per change to a
//     note in a shared notebook (create / edit / delete), written ONLY by the
//     server hook (pb_hooks/activity.pb.js). Every member of the notebook can
//     read it; nobody writes it via the API. Rows age into the client's
//     "archive" view after a week and are finally pruned by a daily cron after
//     ~6 months (activity_lib.PRUNE_AFTER_DAYS) — well beyond the archive window,
//     so nothing is lost prematurely.
//   activity_seen — a per-user read watermark (one row per user): the timestamp
//     the user last marked the feed read. Unread = feed rows newer than this.
//     Global (not per-notebook), owner-scoped, client-written ("mark all read").
//   activity_archives — a per-user, sparse set of manually-archived feed rows
//     (one row per archived item). The default (not archived) is the ABSENCE of
//     a row, so this stays small. Owner-scoped, client-written.
//
// Read state and archive state are per-VIEWER (a feed row is shared, but each
// member reads/archives it independently), which is why they can't be booleans
// on the feed row itself. Auto-archive after a week is derived client-side from
// `created` — no server job, no deletion.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const notes = app.findCollectionByNameOrId("notes");
  const notebooks = app.findCollectionByNameOrId("notebooks");

  // Any member of the feed row's notebook may read it (owner or shared-with).
  const member =
    '@request.auth.id != "" && (' +
    "notebook.owner = @request.auth.id" +
    " || notebook.sharedWith.id ?= @request.auth.id)";

  const activity = new Collection({
    type: "base",
    name: "notebook_activity",
    listRule: member,
    viewRule: member,
    createRule: null, // server-only (written via the hook with $app.save)
    updateRule: null, // immutable once written
    deleteRule: null, // never deleted (rows age into the archive view instead)
    fields: [
      {
        type: "relation",
        name: "notebook",
        required: true,
        maxSelect: 1,
        collectionId: notebooks.id,
        cascadeDelete: true, // deleting the notebook forever clears its feed
      },
      // deleteRule stays null: clients never delete feed rows; the daily prune
      // cron in activity.pb.js uses $app.delete (bypasses API rules).
      {
        type: "relation",
        name: "note",
        required: false,
        maxSelect: 1,
        collectionId: notes.id,
        cascadeDelete: true, // hard-deleting the note forever clears its rows
      },
      {
        type: "relation",
        name: "actor",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: false,
      },
      {
        // Denormalised so the client shows "who" with no user-directory lookup.
        type: "text",
        name: "actorEmail",
        max: 255,
      },
      {
        type: "select",
        name: "action",
        required: true,
        maxSelect: 1,
        values: ["created", "edited", "deleted"],
      },
      {
        // Snapshot of the note's title at the time, so a since-deleted or
        // since-renamed note still reads sensibly in the feed.
        type: "text",
        name: "noteTitle",
        max: 500,
      },
      {
        type: "autodate",
        name: "created",
        onCreate: true,
      },
    ],
    indexes: [
      "CREATE INDEX idx_activity_notebook_created ON notebook_activity (notebook, created)",
      "CREATE INDEX idx_activity_note ON notebook_activity (note)",
    ],
  });
  app.save(activity);

  const owner =
    '@request.auth.id != "" && owner = @request.auth.id';

  const seen = new Collection({
    type: "base",
    name: "activity_seen",
    listRule: owner,
    viewRule: owner,
    createRule: owner,
    updateRule: owner,
    deleteRule: owner,
    fields: [
      {
        type: "relation",
        name: "owner",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: true,
      },
      {
        // ISO timestamp (pbNow-style) the feed was last marked read.
        type: "text",
        name: "seenAt",
        max: 40,
      },
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_activity_seen_owner ON activity_seen (owner)",
    ],
  });
  app.save(seen);

  const archives = new Collection({
    type: "base",
    name: "activity_archives",
    listRule: owner,
    viewRule: owner,
    createRule: owner,
    updateRule: owner,
    deleteRule: owner,
    fields: [
      {
        type: "relation",
        name: "owner",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: true,
      },
      {
        type: "relation",
        name: "activity",
        required: true,
        maxSelect: 1,
        collectionId: activity.id,
        cascadeDelete: true, // if the feed row ever goes, its archive marks go too
      },
      {
        type: "autodate",
        name: "created",
        onCreate: true,
      },
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_activity_archives_owner_activity ON activity_archives (owner, activity)",
    ],
  });
  app.save(archives);
}, (app) => {
  for (const name of [
    "activity_archives",
    "activity_seen",
    "notebook_activity",
  ]) {
    try {
      app.delete(app.findCollectionByNameOrId(name));
    } catch (_) {/* already gone */}
  }
});
