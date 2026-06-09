/// <reference path="../pb_data/types.d.ts" />

// Per-label color: a short color key (see app note_colors.dart) for the label's
// chip. Empty = no color. Syncs like any other label field (LWW).
migrate((app) => {
  const collection = app.findCollectionByNameOrId("labels");
  collection.fields.add(new TextField({
    name: "color",
    max: 20,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("labels");
  if (collection.fields.getByName("color")) {
    collection.fields.removeByName("color");
  }
  app.save(collection);
});
