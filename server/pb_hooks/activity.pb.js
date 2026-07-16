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

function actorOf(e) {
  return e.auth ? { id: e.auth.id, email: e.auth.getString("email") } : null;
}

onRecordAfterCreateSuccess((e) => {
  try {
    const a = actorOf(e);
    if (a) {
      require(`${__hooks}/activity_lib.js`).logActivity(
        $app, e.record, a.id, a.email, "created");
    }
  } catch (err) {
    $app.logger().error("activity log (create) failed", "error", String(err));
  }
  e.next();
}, "notes");

onRecordAfterUpdateSuccess((e) => {
  try {
    const a = actorOf(e);
    if (a) {
      const action = e.record.getBool("deleted") ? "deleted" : "edited";
      require(`${__hooks}/activity_lib.js`).logActivity(
        $app, e.record, a.id, a.email, action);
    }
  } catch (err) {
    $app.logger().error("activity log (update) failed", "error", String(err));
  }
  e.next();
}, "notes");
