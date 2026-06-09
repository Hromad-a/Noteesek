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
  if (collection.fields.getByName("position")) {
    collection.fields.removeByName("position");
  }
  app.save(collection);
});
