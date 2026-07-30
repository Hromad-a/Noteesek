/// <reference path="../pb_data/types.d.ts" />

// Shared-notebook activity feed: write a feed row whenever a member changes a
// note that lives in a shared notebook. Runs server-side so it captures the
// change no matter which client made it (web or mobile). Only genuine member
// actions are logged — a programmatic write (sync, snapshot restore, cron) has
// no e.auth and is skipped by activity_lib. Heavy logic lives in
// activity_lib.js, require()d inside each handler (isolated runtimes — no shared
// outer scope).
//
// Soft delete ("move to trash") is an UPDATE with deleted=true, logged as
// "deleted". Hard delete ("delete forever") is a real record delete; it cascades
// the note's feed rows away, so there's nothing to log — hence no delete hook.

// Daily at 03:30: discard feed rows older than the retention window (see
// activity_lib.PRUNE_AFTER_DAYS). This is the only place feed rows are deleted;
// everything short of it just ages into the client's archive view.
cronAdd("noteesek_activity_prune", "30 3 * * *", () => {
  try {
    require(`${__hooks}/activity_lib.js`).prune($app);
  } catch (err) {
    $app.logger().error("activity prune failed", "error", String(err));
  }
});

// Use the REQUEST hooks (not the AfterSuccess ones): only these carry the
// authenticated actor (e.auth) — the *Success events also fire for programmatic
// writes and have no request auth. e.next() performs the actual save, so we log
// after it (and only if it didn't throw). No feed row for anonymous/programmatic
// writes, which is intended. Each handler runs in its own isolated runtime with
// no access to this file's top-level scope, so everything is read inline / via
// require() inside the handler (same rule the snapshots hook follows).

onRecordCreateRequest((e) => {
  e.next(); // create the record
  try {
    if (e.auth) {
      require(`${__hooks}/activity_lib.js`).logActivity(
        $app, e.record, e.auth.id, e.auth.getString("email"), "created");
    }
  } catch (err) {
    $app.logger().error("activity log (create) failed", "error", String(err));
  }
}, "notes");

onRecordUpdateRequest((e) => {
  e.next(); // apply the update
  try {
    if (e.auth) {
      const action = e.record.getBool("deleted") ? "deleted" : "edited";
      require(`${__hooks}/activity_lib.js`).logActivity(
        $app, e.record, e.auth.id, e.auth.getString("email"), action);
    }
  } catch (err) {
    $app.logger().error("activity log (update) failed", "error", String(err));
  }
}, "notes");
