/// <reference path="../pb_data/types.d.ts" />

// Add `hour` to snapshot_settings: for the **daily** frequency, the hour of day
// (0–23, **UTC**) at which the daily snapshot should run. The hourly cron only
// takes a daily snapshot when the current UTC hour matches. Ignored for the
// hourly frequency. Default 0 (00:00 UTC) so existing rows keep running daily.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("snapshot_settings");
  collection.fields.add(new NumberField({
    name: "hour",
    min: 0,
    max: 23,
    onlyInt: true,
  }));
  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("snapshot_settings");
  if (collection.fields.getByName("hour")) {
    collection.fields.removeByName("hour");
  }
  app.save(collection);
});
