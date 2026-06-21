/// <reference path="../pb_data/types.d.ts" />

// Shared notebooks (phase 1) — add the note-level edit lock fields used for
// pessimistic concurrency in shared notebooks (one editor at a time per note):
//
//   lockedBy  — the user currently editing this note (null = unlocked)
//   lockedAt  — ISO timestamp, refreshed by the holder's heartbeat; a lock whose
//               lockedAt is older than the client's expiry window (~2 min) is
//               treated as stale and may be taken over.
//
// These are plain, client-settable fields (not autodate) because the client
// drives the lock lifecycle. They ride the note's normal last-write-wins sync;
// for personal/private notes they simply stay empty.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const collection = app.findCollectionByNameOrId("notes");

  collection.fields.add(new RelationField({
    name: "lockedBy",
    collectionId: users.id,
    maxSelect: 1,
    cascadeDelete: false,
  }));
  collection.fields.add(new TextField({
    name: "lockedAt",
    max: 40,
  }));

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  for (const f of ["lockedBy", "lockedAt"]) {
    if (collection.fields.getByName(f)) collection.fields.removeByName(f);
  }
  app.save(collection);
});
