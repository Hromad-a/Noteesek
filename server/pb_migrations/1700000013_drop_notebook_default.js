/// <reference path="../pb_data/types.d.ts" />

// Drop the default-notebook concept. Notes may now have no notebook at all, so
// the per-user fallback notebook (`is_default = true`) is obsolete.
//
// 1. Move every note out of a default notebook into "no notebook" (empty
//    relation) and soft-delete the default notebooks. `updated` is bumped so the
//    changes propagate to mobile clients on their next pull.
// 2. Remove the `is_default` field from the notebooks collection.
migrate((app) => {
  // PocketBase datetime format: "2006-01-02 15:04:05.000Z".
  const now = new Date().toISOString().replace("T", " ");

  app.db()
    .newQuery(
      "UPDATE notes SET notebook = '', updated = {:now} " +
        "WHERE notebook IN (SELECT id FROM notebooks WHERE is_default = true)"
    )
    .bind({ now: now })
    .execute();

  app.db()
    .newQuery(
      "UPDATE notebooks SET deleted = true, updated = {:now} " +
        "WHERE is_default = true"
    )
    .bind({ now: now })
    .execute();

  const collection = app.findCollectionByNameOrId("notebooks");
  if (collection.fields.getByName("is_default")) {
    collection.fields.removeByName("is_default");
  }
  app.save(collection);
}, (app) => {
  // Down: re-add the field (the flagged-default data is not restored).
  const collection = app.findCollectionByNameOrId("notebooks");
  collection.fields.add(new BoolField({ name: "is_default" }));
  app.save(collection);
});
