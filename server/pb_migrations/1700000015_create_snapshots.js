/// <reference path="../pb_data/types.d.ts" />

// snapshots — server-side, per-account point-in-time backups (version history).
// Each record stores a JSON blob of the owner's whole account (notes, checklist
// items, attachment metadata, labels, notebooks) in the same layout as the
// manual JSON backup (BackupService.formatVersion). Image bytes are NOT inlined
// here — they're deduplicated into the `snapshot_blobs` collection and
// referenced by attachment id, so a snapshot only ever stores changed content.
//
// Snapshots are created exclusively server-side (the scheduled cron in
// pb_hooks/snapshots.pb.js, or the "back up now" route), so there is no client
// create/update rule — only owner-scoped list/view/delete.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "snapshots",
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: null, // server-only (created via hook with $app.save)
    updateRule: null, // immutable once written
    deleteRule: "owner = @request.auth.id",
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
        // The account JSON (same shape as the manual backup), stored as a file
        // so large accounts don't bloat the DB row / realtime payloads.
        type: "file",
        name: "file",
        required: false,
        maxSelect: 1,
        maxSize: 52428800, // 50 MB
        protected: true,
      },
      {
        // 'auto' (scheduled), 'manual' ("back up now"), or 'pre-restore'
        // (safety snapshot taken automatically before a restore).
        type: "text",
        name: "reason",
        max: 20,
      },
      {
        // Number of (non-deleted) notes captured — shown in the snapshot list.
        type: "number",
        name: "noteCount",
      },
      {
        // Size of the JSON file in bytes — shown in the snapshot list.
        type: "number",
        name: "byteSize",
      },
      {
        // The highest `updated` timestamp seen across the account at capture
        // time. The cron compares this against the live max to decide whether
        // anything changed since the last snapshot ("only when changed").
        type: "text",
        name: "highWater",
        max: 50,
      },
      {
        // How many (non-deleted) records the account held at capture time.
        // A pure "delete forever" doesn't bump `updated`, so a count change is
        // the second change-detection signal alongside `highWater`.
        type: "number",
        name: "recordCount",
      },
      {
        // The attachment ids this snapshot has bytes for in `snapshot_blobs`.
        // Used for mark-and-sweep blob garbage-collection on prune/delete: a
        // blob is removed once no surviving snapshot lists its attachment id.
        type: "json",
        name: "blobRefs",
        maxSize: 2000000,
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
      "CREATE INDEX idx_snapshots_owner_created ON snapshots (owner, created)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("snapshots");
  app.delete(collection);
});
