/// <reference path="../pb_data/types.d.ts" />

// Scheduled server-side snapshots (per-account version history / backups).
//
// - Hourly cron: for each account with snapshots enabled, take a snapshot when
//   one is *due* (per their hourly/daily frequency) AND something *changed*
//   since the last one, then prune snapshots older than their retention window.
// - POST /api/noteesek/snapshots          → take a snapshot now ("back up now").
// - POST /api/noteesek/snapshots/{id}/restore → restore (whole-account replace,
//   or selected notes only); always takes a safety snapshot first.
// - After a snapshot is deleted (by prune or by the owner), garbage-collect any
//   image blobs no longer referenced by a surviving snapshot.
//
// The heavy lifting lives in snapshots_lib.js, require()d inside each handler
// because PocketBase runs handlers in isolated runtimes (no shared outer scope).

cronAdd("noteesek_snapshots", "0 * * * *", () => {
  require(`${__hooks}/snapshots_lib.js`).runDueSnapshots($app);
});

routerAdd(
  "POST",
  "/api/noteesek/snapshots",
  (e) => {
    if (!e.auth) throw new UnauthorizedError("Not authenticated.");
    const lib = require(`${__hooks}/snapshots_lib.js`);
    const ownerId = e.auth.id;
    const rec = lib.buildSnapshot($app, ownerId, "manual");
    let retention = lib.DEFAULT_RETENTION_DAYS;
    try {
      const st = $app.findFirstRecordByFilter(
        "snapshot_settings", "owner = {:o}", { o: ownerId });
      retention = st.getInt("retentionDays") || retention;
    } catch (_) {/* no settings row yet — use default */}
    lib.pruneAndSweep($app, ownerId, retention);
    return e.json(200, {
      id: rec.id,
      noteCount: rec.getInt("noteCount"),
      byteSize: rec.getInt("byteSize"),
    });
  },
  $apis.requireAuth(),
);

routerAdd(
  "POST",
  "/api/noteesek/snapshots/{id}/restore",
  (e) => {
    if (!e.auth) throw new UnauthorizedError("Not authenticated.");
    const lib = require(`${__hooks}/snapshots_lib.js`);
    const id = e.request.pathValue("id");
    const body = e.requestInfo().body || {};
    const mode = body.mode === "replace" ? "replace" : "notes";
    const noteIds = Array.isArray(body.noteIds) ? body.noteIds : [];
    if (mode === "notes" && noteIds.length === 0) {
      throw new BadRequestError("No notes selected to restore.");
    }
    const res = lib.restoreSnapshot($app, e.auth.id, id, mode, noteIds);
    return e.json(200, res);
  },
  $apis.requireAuth(),
);

// Blob garbage-collection: when a snapshot is removed (prune or owner delete),
// drop any image blob no longer referenced by a surviving snapshot. Fires for
// both programmatic ($app.delete) and API deletes.
onRecordAfterDeleteSuccess((e) => {
  try {
    const lib = require(`${__hooks}/snapshots_lib.js`);
    lib.sweepBlobs($app, e.record.getString("owner"));
  } catch (err) {
    $app.logger().error("snapshot blob sweep failed", "error", String(err));
  }
  e.next();
}, "snapshots");
