/// <reference path="../pb_data/types.d.ts" />

// Add a "hidden from All notes" flag to notebooks. Stored inverted (default
// false = visible) so existing rows stay visible without a backfill. When true,
// the notebook's notes are excluded from the app's "All notes" view.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("notebooks");
  collection.fields.add(new BoolField({
    name: "hidden_from_all",
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notebooks");
  if (collection.fields.getByName("hidden_from_all")) {
    collection.fields.removeByName("hidden_from_all");
  }
  app.save(collection);
});
