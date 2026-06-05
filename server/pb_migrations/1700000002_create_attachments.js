/// <reference path="../pb_data/types.d.ts" />

// attachments — images / files attached to a note.
// Stored in PocketBase's file storage; access derived from the parent note.
migrate((app) => {
  const notes = app.findCollectionByNameOrId("notes");

  const collection = new Collection({
    type: "base",
    name: "attachments",
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
        type: "file",
        name: "file",
        required: true,
        maxSelect: 1,
        maxSize: 26214400, // 25 MB
        // mimeTypes left permissive to allow images and general attachments.
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
      "CREATE INDEX idx_attachments_note ON attachments (note)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("attachments");
  app.delete(collection);
});
