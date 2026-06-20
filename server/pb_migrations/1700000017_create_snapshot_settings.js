/// <reference path="../pb_data/types.d.ts" />

// snapshot_settings — per-account configuration for scheduled snapshots.
//
// One row per user (unique on owner). The hourly cron reads every enabled row
// and decides, per user, whether a snapshot is due (based on `frequency`) and
// prunes snapshots older than `retentionDays`. Owner-scoped read/write so each
// user manages their own schedule; the row is created/updated from the client
// settings screen. Missing/empty values fall back to sensible defaults in the
// hook (enabled, daily, 14 days).
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "snapshot_settings",
    listRule: "owner = @request.auth.id",
    viewRule: "owner = @request.auth.id",
    createRule: "owner = @request.auth.id",
    updateRule: "owner = @request.auth.id",
    deleteRule: "owner = @request.auth.id",
    fields: [
      {
        type: "relation",
        name: "owner",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: true,
      },
      {
        type: "bool",
        name: "enabled",
      },
      {
        // 'hourly' | 'daily'. Empty is treated as 'daily' by the cron.
        type: "text",
        name: "frequency",
        max: 10,
      },
      {
        // How many days of snapshots to keep. <= 0 / empty → default 14.
        type: "number",
        name: "retentionDays",
      },
      {
        type: "autodate",
        name: "created",
        onCreate: true,
      },
      {
        type: "autodate",
        name: "updated",
        onCreate: true,
        onUpdate: true,
      },
    ],
    indexes: [
      "CREATE UNIQUE INDEX idx_snapshot_settings_owner ON snapshot_settings (owner)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("snapshot_settings");
  app.delete(collection);
});
