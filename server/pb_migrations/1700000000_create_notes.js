/// <reference path="../pb_data/types.d.ts" />

// notes — the core Keep-style note.
// One note = one text note OR one checklist (items live in checklist_items).
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "notes",
    // Owner-scoped: a user only ever sees/touches their own notes.
    // createRule enforces that owner is set to the authenticated user.
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
        type: "select",
        name: "type",
        required: true,
        maxSelect: 1,
        values: ["text", "checklist"],
      },
      {
        type: "text",
        name: "title",
        max: 500,
      },
      {
        // Body text for type=text notes. Empty for checklists.
        type: "text",
        name: "body",
      },
      {
        type: "bool",
        name: "pinned",
      },
      {
        type: "bool",
        name: "archived",
      },
      {
        // Soft delete so deletions propagate during sync, then purge later.
        type: "bool",
        name: "deleted",
      },
      {
        type: "autodate",
        name: "created",
        onCreate: true,
      },
      {
        // Drives last-write-wins sync: clients pull notes changed since a cursor.
        type: "autodate",
        name: "updated",
        onCreate: true,
        onUpdate: true,
      },
    ],
    indexes: [
      "CREATE INDEX idx_notes_owner_updated ON notes (owner, updated)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  app.delete(collection);
});
