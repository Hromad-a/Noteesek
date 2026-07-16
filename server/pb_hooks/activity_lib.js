/// <reference path="../pb_data/types.d.ts" />

// Core logic for the shared-notebook activity feed. require()d from
// activity.pb.js inside each handler (PocketBase runs handlers in isolated
// runtimes — no shared outer scope).

// A run of same-actor changes within this window collapses into one feed row,
// so a burst of content-saves (or a create immediately followed by typing)
// doesn't flood the feed.
const COALESCE_SECONDS = 60;

// Feed rows older than this are deleted by the daily prune cron. Entries
// auto-archive by age after a week (client-side, no deletion); this is the far
// outer bound where an archived row is finally discarded. Deleting the feed row
// cascade-removes its per-user archive marks (activity_archives.activity).
const PRUNE_AFTER_DAYS = 180;

// PocketBase timestamps ("2026-06-18 14:43:00.123Z", space not T) sort
// lexicographically, so a formatted cutoff works directly in a `created <` filter.
function toPbTime(date) {
  return date.toISOString().replace("T", " ");
}

function fromPbTime(s) {
  return new Date(String(s || "").replace(" ", "T"));
}

// Is this note in a notebook shared with at least one other user? Uses a
// filtered count (`sharedWith:length`) so we never have to read the relation
// array out in JS.
function noteIsInSharedNotebook(app, note) {
  const nbId = note.getString("notebook");
  if (!nbId) return false;
  try {
    const rows = app.findRecordsByFilter(
      "notebooks",
      "id = {:id} && sharedWith:length > 0",
      "",
      1,
      0,
      { id: nbId }
    );
    return rows.length > 0;
  } catch (_) {
    return false;
  }
}

// The most recent feed row for this note by this actor, or null.
function lastByActor(app, noteId, actorId) {
  try {
    const rows = app.findRecordsByFilter(
      "notebook_activity",
      "note = {:n} && actor = {:a}",
      "-created",
      1,
      0,
      { n: noteId, a: actorId }
    );
    return rows.length > 0 ? rows[0] : null;
  } catch (_) {
    return null;
  }
}

// True if the previous row makes this new one redundant (same actor, moments
// ago): a fresh edit folds into a recent edit/create; a delete folds into a
// recent delete. A create is always its own row.
function coalesces(last, action) {
  if (!last) return false;
  const ageSec = (Date.now() - fromPbTime(last.getString("created")).getTime()) / 1000;
  if (ageSec >= COALESCE_SECONDS) return false;
  const prev = last.getString("action");
  if (action === "edited") return prev === "edited" || prev === "created";
  if (action === "deleted") return prev === "deleted";
  return false;
}

// Write one feed row for a change to a note in a shared notebook. No-ops for
// programmatic changes (no actor) and notes outside a shared notebook.
function logActivity(app, note, actorId, actorEmail, action) {
  if (!actorId) return; // sync / restore / cron — not a member action
  if (!noteIsInSharedNotebook(app, note)) return;
  if (coalesces(lastByActor(app, note.id, actorId), action)) return;

  const rec = new Record(app.findCollectionByNameOrId("notebook_activity"));
  rec.set("notebook", note.getString("notebook"));
  rec.set("note", note.id);
  rec.set("actor", actorId);
  rec.set("actorEmail", actorEmail || "");
  rec.set("action", action);
  rec.set("noteTitle", note.getString("title"));
  app.save(rec);
}

// Delete feed rows older than PRUNE_AFTER_DAYS, in batches (a cascade on each
// delete removes any per-user archive marks that referenced them). Bounded so a
// backlog can't spin the cron forever — leftovers go on the next daily run.
function prune(app) {
  const cutoff = toPbTime(new Date(Date.now() - PRUNE_AFTER_DAYS * 86400 * 1000));
  for (let batch = 0; batch < 50; batch++) {
    const rows = app.findRecordsByFilter(
      "notebook_activity",
      "created < {:c}",
      "created",
      200,
      0,
      { c: cutoff }
    );
    if (rows.length === 0) break;
    for (const r of rows) app.delete(r);
    if (rows.length < 200) break;
  }
}

module.exports = { logActivity, prune };
