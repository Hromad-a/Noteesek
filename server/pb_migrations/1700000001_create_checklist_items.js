/// <reference path="../pb_data/types.d.ts" />

// checklist_items — individual checkable rows belonging to a checklist note.
// Access is derived from the parent note's owner via relation traversal.
migrate((app) => {
  const notes = app.findCollectionByNameOrId("notes");

  const collection = new Collection({
    type: "base",
    name: "checklist_items",
    listRule: "note.owner = @request.auth.id",
    viewRule: "note.owner = @request.auth.id",
    createRule: "note.owner = @request.auth.id",
    updateRule: "note.owner = @request.auth.id",
    deleteRule: "note.owner = @request.auth.id",
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
        type: "text",
        name: "text",
        max: 2000,
      },
      {
        type: "bool",
        name: "checked",
      },
      {
        // Sort order within the checklist.
        type: "number",
        name: "position",
      },
      {
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
      "CREATE INDEX idx_checklist_items_note ON checklist_items (note, position)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("checklist_items");
  app.delete(collection);
});
