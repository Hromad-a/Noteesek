/// <reference path="../pb_data/types.d.ts" />

// Add a single-relation `background` field to notes — the image background a
// note uses (from the owner's backgrounds library). Optional; empty/unknown =
// no background (the note falls back to its color / plain card). Mutually
// exclusive with `color` in the UI. Rides the note's last-write-wins sync.
migrate((app) => {
  const backgrounds = app.findCollectionByNameOrId("backgrounds");
  const collection = app.findCollectionByNameOrId("notes");
  collection.fields.add(new RelationField({
    name: "background",
    collectionId: backgrounds.id,
    maxSelect: 1,
    cascadeDelete: false,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  if (collection.fields.getByName("background")) {
    collection.fields.removeByName("background");
  }
  app.save(collection);
});
