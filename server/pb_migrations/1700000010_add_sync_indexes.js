/// <reference path="../pb_data/types.d.ts" />

// Sync reliability/performance: the pull step queries each collection by
// `updated >= cursor` ordered by `updated`. notes/labels/notebooks already have
// composite (owner, updated) indexes, but checklist_items and attachments (whose
// access derives from the parent note) only had a `note` index — so every
// incremental pull scanned the whole table and re-sorted it. Add `updated`
// indexes so those pulls stay O(changed) as data grows.
migrate((app) => {
  const ci = app.findCollectionByNameOrId("checklist_items");
  ci.indexes = [
    ...ci.indexes,
    "CREATE INDEX idx_checklist_items_updated ON checklist_items (updated)",
  ];
  app.save(ci);

  const at = app.findCollectionByNameOrId("attachments");
  at.indexes = [
    ...at.indexes,
    "CREATE INDEX idx_attachments_updated ON attachments (updated)",
  ];
  app.save(at);
}, (app) => {
  const ci = app.findCollectionByNameOrId("checklist_items");
  ci.indexes = ci.indexes.filter(
    (i) => !i.includes("idx_checklist_items_updated"),
  );
  app.save(ci);

  const at = app.findCollectionByNameOrId("attachments");
  at.indexes = at.indexes.filter(
    (i) => !i.includes("idx_attachments_updated"),
  );
  app.save(at);
});
