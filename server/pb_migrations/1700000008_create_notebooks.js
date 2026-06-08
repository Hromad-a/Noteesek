/// <reference path="../pb_data/types.d.ts" />

// notebooks — collections of notes (like a real-world notebook). Owner-scoped
// like notes/labels; a note belongs to exactly one notebook via a single
// relation field on the notes collection (added in the next migration). Each
// user has one default notebook (`is_default = true`) that can be renamed but
// not deleted.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "notebooks",
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
        // Marks the per-user fallback notebook (rename-only, never deleted).
        type: "bool",
        name: "is_default",
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
      "CREATE INDEX idx_notebooks_owner_updated ON notebooks (owner, updated)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notebooks");
  app.delete(collection);
});
