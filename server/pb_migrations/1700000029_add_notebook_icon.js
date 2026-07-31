/// <reference path="../pb_data/types.d.ts" />

// Per-notebook icon: a short icon key (see app notebook_icons.dart) chosen on the
// Manage Notebooks screen. Empty = the default book icon. Syncs like any other
// notebook field (LWW).
migrate((app) => {
  const collection = app.findCollectionByNameOrId("notebooks");
  collection.fields.add(new TextField({
    name: "icon",
    max: 40,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notebooks");
  if (collection.fields.getByName("icon")) {
    collection.fields.removeByName("icon");
  }
  app.save(collection);
});
