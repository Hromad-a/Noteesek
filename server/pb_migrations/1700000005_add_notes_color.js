/// <reference path="../pb_data/types.d.ts" />

// Add a background color key to notes (see app note_colors.dart). Empty = default.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("notes");
  collection.fields.add(new TextField({
    name: "color",
    max: 30,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notes");
  if (collection.fields.getByName("color")) {
    collection.fields.removeByName("color");
  }
  app.save(collection);
});
