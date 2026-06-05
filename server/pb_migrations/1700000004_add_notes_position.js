/// <reference path="../pb_data/types.d.ts" />

// Add manual sort position to notes so users can reorder their notes.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("notes");
  collection.fields.add(new NumberField({
    name: "position",
    min: 0,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  const field = collection.fields.getByName("position");
  if (field) collection.fields.remove(field);
  app.save(collection);
});
