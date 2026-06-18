/// <reference path="../pb_data/types.d.ts" />

// snapshot_blobs — content-deduplicated image storage for snapshots.
//
// A snapshot is a *complete* point-in-time copy, so naively embedding image
// bytes would re-store every image in every snapshot. Instead, each unique
// attachment's bytes are copied here exactly once (keyed by the original
// attachment id, which is immutable — editing an image means a new attachment
// record, hence a new id). Snapshots reference blobs by attachment id, and a
// blob survives even if the live attachment is later hard-deleted, so restores
// stay lossless. Pruning is mark-and-sweep: when a snapshot is deleted, any of
// its blobs no longer referenced by a surviving snapshot are removed
// (pb_hooks/snapshots.pb.js).
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "snapshot_blobs",
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: null, // server-only
    updateRule: null,
    deleteRule: null, // removed only by the prune hook
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
        // The original attachments.id whose bytes this blob holds (dedup key).
        type: "text",
        name: "attachment",
        required: true,
        max: 50,
      },
      {
        type: "file",
        name: "file",
        required: false,
        maxSelect: 1,
        maxSize: 26214400, // 25 MB (matches attachments)
        protected: true,
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
      "CREATE UNIQUE INDEX idx_snapshot_blobs_owner_attachment ON snapshot_blobs (owner, attachment)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("snapshot_blobs");
  app.delete(collection);
});
