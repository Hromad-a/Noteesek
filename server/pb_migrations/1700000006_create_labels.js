/// <reference path="../pb_data/types.d.ts" />

// labels — user-defined tags. Owner-scoped like notes; assigned to notes via a
// multi-relation field on the notes collection (added in the next migration).
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "labels",
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: "owner = @request.auth.id",
    updateRule: "owner = @request.auth.id",
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
        type: "text",
        name: "name",
        required: true,
        max: 100,
      },
      {
        // Soft delete so removals propagate during sync, then purge later.
        type: "bool",
        name: "deleted",
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
      "CREATE INDEX idx_labels_owner_updated ON labels (owner, updated)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("labels");
  app.delete(collection);
});
