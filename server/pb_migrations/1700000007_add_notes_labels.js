/// <reference path="../pb_data/types.d.ts" />

// Add a multi-relation `labels` field to notes (assigned labels). Membership
// changes ride the note's last-write-wins sync.
migrate((app) => {
  const labels = app.findCollectionByNameOrId("labels");
  const collection = app.findCollectionByNameOrId("notes");
  collection.fields.add(new RelationField({
    name: "labels",
    collectionId: labels.id,
    maxSelect: 50,
    cascadeDelete: false,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  if (collection.fields.getByName("labels")) {
    collection.fields.removeByName("labels");
  }
  app.save(collection);
});
