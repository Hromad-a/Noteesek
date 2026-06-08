/// <reference path="../pb_data/types.d.ts" />

// Add a single-relation `notebook` field to notes (the notebook a note lives
// in). Not required so existing notes stay valid; an empty/unknown notebook is
// treated as the default notebook by the client. Changes ride the note's
// last-write-wins sync.
migrate((app) => {
  const notebooks = app.findCollectionByNameOrId("notebooks");
  const collection = app.findCollectionByNameOrId("notes");
  collection.fields.add(new RelationField({
    name: "notebook",
    collectionId: notebooks.id,
    maxSelect: 1,
    cascadeDelete: false,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  const field = collection.fields.getByName("notebook");
  if (field) collection.fields.remove(field);
  app.save(collection);
});
