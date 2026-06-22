/// <reference path="../pb_data/types.d.ts" />

// Shared logic for the scheduled snapshot (version history) feature, required()
// by snapshots.pb.js. It lives in a plain (non-".pb.js") file so PocketBase
// doesn't auto-load it as a hook — it's only pulled in via require() inside the
// cron/route handlers (PocketBase runs each handler in an isolated runtime, so
// shared code must be require()d, not referenced from an outer scope).
//
// A snapshot is a complete point-in-time copy of one account, serialized to the
// same JSON layout as the manual backup (BackupService.formatVersion = 1) and
// stored as a file. Image bytes are deduplicated into snapshot_blobs (one copy
// per attachment id), so repeated snapshots only cost the changed text.

const FORMAT_VERSION = 1;
const DEFAULT_RETENTION_DAYS = 14;
const READ_LIMIT = 52428800; // 50 MB cap when reading a snapshot's JSON

// PocketBase stores timestamps like "2026-06-18 14:43:00.123Z" (space, not T)
// and they sort lexicographically. Match that when we need to emit one.
function toPbTime(date) {
  return date.toISOString().replace("T", " ");
}

function fromPbTime(s) {
  return new Date(String(s || "").replace(" ", "T"));
}

function intervalSeconds(frequency) {
  return frequency === "hourly" ? 3600 : 86400; // default daily
}

// Whether a snapshot is due now for these settings, given the last snapshot
// (or null). Hourly: at least an hour since the last. Daily: only at the
// configured UTC `hour`, and not already taken today (UTC calendar day).
function isDue(s, last) {
  const freq = s.getString("frequency") || "daily";
  if (freq === "hourly") {
    if (!last) return true;
    const elapsed =
      (Date.now() - fromPbTime(last.getString("created")).getTime()) / 1000;
    return elapsed >= 3600;
  }
  // daily
  const now = new Date();
  if (now.getUTCHours() !== s.getInt("hour")) return false; // not the hour
  if (!last) return true;
  const lastAt = fromPbTime(last.getString("created"));
  const sameUtcDay =
    lastAt.getUTCFullYear() === now.getUTCFullYear() &&
    lastAt.getUTCMonth() === now.getUTCMonth() &&
    lastAt.getUTCDate() === now.getUTCDate();
  return !sameUtcDay; // once per UTC day
}

// ---- collect one account's records ----

function collect(app, ownerId) {
  const p = { o: ownerId };
  return {
    notes: app.findRecordsByFilter("notes", "owner = {:o}", "created", 0, 0, p),
    labels: app.findRecordsByFilter("labels", "owner = {:o}", "created", 0, 0, p),
    notebooks: app.findRecordsByFilter("notebooks", "owner = {:o}", "created", 0, 0, p),
    items: app.findRecordsByFilter("checklist_items", "note.owner = {:o}", "created", 0, 0, p),
    attachments: app.findRecordsByFilter("attachments", "note.owner = {:o}", "created", 0, 0, p),
  };
}

function maxUpdated(data) {
  let hi = "";
  const all = [].concat(data.notes, data.labels, data.notebooks, data.items, data.attachments);
  for (const r of all) {
    if (!r) continue;
    const u = r.getString("updated");
    if (u > hi) hi = u;
  }
  return hi;
}

// ---- record → JSON (mirrors RemoteBackupService) ----

function noteJson(n) {
  let labels = n.get("labels");
  if (!labels) labels = [];
  return {
    id: n.id,
    owner: n.getString("owner"),
    type: n.getString("type"),
    title: n.getString("title"),
    body: n.getString("body"),
    pinned: n.getBool("pinned"),
    archived: n.getBool("archived"),
    color: n.getString("color"),
    background: n.getString("background"),
    labels: JSON.stringify(labels),
    notebook: n.getString("notebook"),
    deleted: n.getBool("deleted"),
    created: n.getString("created"),
    updated: n.getString("updated"),
    position: n.getInt("position"),
  };
}

function itemJson(i) {
  return {
    id: i.id,
    note: i.getString("note"),
    content: i.getString("text"),
    checked: i.getBool("checked"),
    position: i.getInt("position"),
    deleted: i.getBool("deleted"),
    created: i.getString("created"),
    updated: i.getString("updated"),
  };
}

// Attachments carry NO base64 here — bytes live in snapshot_blobs, keyed by id.
function attachmentJson(a) {
  return {
    id: a.id,
    note: a.getString("note"),
    file: a.getString("file"),
    deleted: a.getBool("deleted"),
    created: a.getString("created"),
    updated: a.getString("updated"),
  };
}

function labelJson(l) {
  return {
    id: l.id,
    owner: l.getString("owner"),
    name: l.getString("name"),
    color: l.getString("color"),
    deleted: l.getBool("deleted"),
    created: l.getString("created"),
    updated: l.getString("updated"),
  };
}

function notebookJson(n) {
  return {
    id: n.id,
    owner: n.getString("owner"),
    name: n.getString("name"),
    deleted: n.getBool("deleted"),
    created: n.getString("created"),
    updated: n.getString("updated"),
  };
}

function serialize(data) {
  return {
    format: FORMAT_VERSION,
    exportedAt: new Date().toISOString(),
    notes: data.notes.map(noteJson),
    checklistItems: data.items.map(itemJson),
    attachments: data.attachments.map(attachmentJson),
    labels: data.labels.map(labelJson),
    notebooks: data.notebooks.map(notebookJson),
  };
}

function blobFor(app, ownerId, attachmentId) {
  try {
    return app.findFirstRecordByFilter(
      "snapshot_blobs",
      "owner = {:o} && attachment = {:a}",
      { o: ownerId, a: attachmentId },
    );
  } catch (_) {
    return null; // none exists yet
  }
}

// Ensure each live, non-deleted attachment's bytes are stored once in
// snapshot_blobs. Returns the list of attachment ids that have a blob (the
// snapshot's blobRefs, used later for garbage-collection).
function ensureBlobs(app, ownerId, attachments) {
  const refs = [];
  const fsys = $app.newFilesystem();
  try {
    const blobs = app.findCollectionByNameOrId("snapshot_blobs");
    for (const a of attachments) {
      if (!a || a.getBool("deleted")) continue;
      const filename = a.getString("file");
      if (!filename) continue;
      refs.push(a.id);
      if (blobFor(app, ownerId, a.id)) continue; // already stored
      const file = fsys.getReuploadableFile(a.baseFilesPath() + "/" + filename, true);
      const blob = new Record(blobs);
      blob.set("owner", ownerId);
      blob.set("attachment", a.id);
      blob.set("file", file);
      app.save(blob);
    }
  } finally {
    fsys.close();
  }
  return refs;
}

// ---- snapshot creation ----

function buildSnapshot(app, ownerId, reason) {
  const data = collect(app, ownerId);
  const blobRefs = ensureBlobs(app, ownerId, data.attachments);
  const json = JSON.stringify(serialize(data));

  const noteCount = data.notes.filter((n) => n && !n.getBool("deleted")).length;
  const recordCount = data.notes.length + data.labels.length + data.notebooks.length;

  const rec = new Record(app.findCollectionByNameOrId("snapshots"));
  rec.set("owner", ownerId);
  rec.set("reason", reason || "auto");
  rec.set("noteCount", noteCount);
  rec.set("byteSize", json.length);
  rec.set("highWater", maxUpdated(data));
  rec.set("recordCount", recordCount);
  rec.set("blobRefs", blobRefs);
  rec.set("file", $filesystem.fileFromBytes(json, "snapshot.json"));
  app.save(rec);
  return rec;
}

// Cheap "has anything changed?" probe for the cron (avoids serializing an
// unchanged account). Returns { high, count } where `count` mirrors the
// owner-scoped collections used for recordCount.
function currentStats(app, ownerId) {
  const p = { o: ownerId };
  const probes = [
    ["notes", "owner = {:o}"],
    ["labels", "owner = {:o}"],
    ["notebooks", "owner = {:o}"],
    ["checklist_items", "note.owner = {:o}"],
    ["attachments", "note.owner = {:o}"],
  ];
  let high = "";
  for (const [coll, filter] of probes) {
    const r = app.findRecordsByFilter(coll, filter, "-updated", 1, 0, p);
    if (r.length && r[0]) {
      const u = r[0].getString("updated");
      if (u > high) high = u;
    }
  }
  const count =
    app.countRecords("notes", $dbx.exp("owner = {:o}", p)) +
    app.countRecords("labels", $dbx.exp("owner = {:o}", p)) +
    app.countRecords("notebooks", $dbx.exp("owner = {:o}", p));
  return { high: high, count: count };
}

function latestSnapshot(app, ownerId) {
  const r = app.findRecordsByFilter("snapshots", "owner = {:o}", "-created", 1, 0, { o: ownerId });
  return r.length ? r[0] : null;
}

// ---- scheduled tick ----

// One pass of the hourly cron: for every account with snapshots enabled, take a
// snapshot when it's *due* (per its frequency) AND something *changed* since the
// last one, then prune past its retention. Each account is isolated so one
// failure can't strand the rest. Extracted here so it's unit-testable.
function runDueSnapshots(app) {
  const settings = app.findRecordsByFilter("snapshot_settings", "enabled = true", "", 0, 0);
  for (const s of settings) {
    if (!s) continue;
    const ownerId = s.getString("owner");
    try {
      const last = latestSnapshot(app, ownerId);
      if (!isDue(s, last)) continue; // not due (frequency / scheduled hour)
      const stats = currentStats(app, ownerId);
      if (!last && stats.count === 0 && stats.high === "") continue; // empty account
      if (last && stats.high <= last.getString("highWater") &&
          stats.count === last.getInt("recordCount")) {
        continue; // nothing changed since the last snapshot
      }
      buildSnapshot(app, ownerId, "auto");
      pruneAndSweep(app, ownerId, s.getInt("retentionDays"));
    } catch (err) {
      app.logger().error("snapshot cron failed", "owner", ownerId, "error", String(err));
    }
  }
}

// ---- pruning + blob GC ----

function pruneAndSweep(app, ownerId, retentionDays) {
  const days = retentionDays > 0 ? retentionDays : DEFAULT_RETENTION_DAYS;
  const cutoff = toPbTime(new Date(Date.now() - days * 86400 * 1000));
  const old = app.findRecordsByFilter(
    "snapshots",
    "owner = {:o} && created < {:c}",
    "created",
    0,
    0,
    { o: ownerId, c: cutoff },
  );
  for (const s of old) {
    if (s) app.delete(s);
  }
  sweepBlobs(app, ownerId);
}

// Delete any blob whose attachment id is no longer referenced by a surviving
// snapshot of this owner. Reads only the (small) blobRefs arrays, never the
// snapshot files.
function sweepBlobs(app, ownerId) {
  const survivors = app.findRecordsByFilter("snapshots", "owner = {:o}", "", 0, 0, { o: ownerId });
  const referenced = {};
  for (const s of survivors) {
    if (!s) continue;
    // A `json` field comes back as a Go JsonRaw (byte slice), so decode the
    // bytes to text with toString() before parsing — JSON.stringify on it would
    // yield an array of byte numbers, and we'd wrongly GC live blobs.
    let refs = [];
    try {
      const str = toString(s.get("blobRefs"));
      if (str) refs = JSON.parse(str);
    } catch (_) { refs = []; }
    for (let i = 0; i < refs.length; i++) referenced[refs[i]] = true;
  }
  const blobs = app.findRecordsByFilter("snapshot_blobs", "owner = {:o}", "", 0, 0, { o: ownerId });
  for (const b of blobs) {
    if (b && !referenced[b.getString("attachment")]) app.delete(b);
  }
}

// ---- restore ----

function readSnapshotJson(app, snap) {
  const fsys = $app.newFilesystem();
  try {
    const reader = fsys.getReader(snap.baseFilesPath() + "/" + snap.getString("file"));
    return JSON.parse(readerToString(reader, READ_LIMIT));
  } finally {
    fsys.close();
  }
}

function setOrCreate(app, collName, id) {
  try {
    return app.findRecordById(collName, id);
  } catch (_) {
    const rec = new Record(app.findCollectionByNameOrId(collName));
    rec.set("id", id);
    return rec;
  }
}

function restoreNotebook(app, ownerId, m) {
  const r = setOrCreate(app, "notebooks", m.id);
  r.set("owner", ownerId);
  r.set("name", m.name || "");
  r.set("deleted", !!m.deleted);
  app.save(r);
}

function restoreLabel(app, ownerId, m) {
  const r = setOrCreate(app, "labels", m.id);
  r.set("owner", ownerId);
  r.set("name", m.name || "");
  r.set("color", m.color || "");
  r.set("deleted", !!m.deleted);
  app.save(r);
}

function restoreNote(app, ownerId, m) {
  const r = setOrCreate(app, "notes", m.id);
  r.set("owner", ownerId);
  r.set("type", m.type || "text");
  r.set("title", m.title || "");
  r.set("body", m.body || "");
  r.set("pinned", !!m.pinned);
  r.set("archived", !!m.archived);
  r.set("color", m.color || "");
  r.set("background", m.background || "");
  let labels = [];
  try { labels = JSON.parse(m.labels || "[]"); } catch (_) { labels = []; }
  r.set("labels", labels);
  r.set("notebook", m.notebook || "");
  r.set("deleted", !!m.deleted);
  r.set("position", m.position || 0);
  app.save(r);
}

function restoreItem(app, m) {
  const r = setOrCreate(app, "checklist_items", m.id);
  r.set("note", m.note);
  r.set("text", m.content || "");
  r.set("checked", !!m.checked);
  r.set("position", m.position || 0);
  r.set("deleted", !!m.deleted);
  app.save(r);
}

function restoreAttachment(app, ownerId, m) {
  try {
    const r = app.findRecordById("attachments", m.id);
    r.set("deleted", !!m.deleted);
    app.save(r);
    return;
  } catch (_) {
    // Gone from the live account — recreate its bytes from the blob store.
  }
  if (m.deleted) return; // nothing to recreate for a deleted attachment
  const blob = blobFor(app, ownerId, m.id);
  if (!blob) return; // no bytes preserved — skip
  const fsys = $app.newFilesystem();
  try {
    const file = fsys.getReuploadableFile(blob.baseFilesPath() + "/" + blob.getString("file"), true);
    const r = new Record(app.findCollectionByNameOrId("attachments"));
    r.set("id", m.id);
    r.set("note", m.note);
    r.set("deleted", false);
    r.set("file", file);
    app.save(r);
  } finally {
    fsys.close();
  }
}

function softDelete(app, collName, id) {
  try {
    const r = app.findRecordById(collName, id);
    if (!r.getBool("deleted")) {
      r.set("deleted", true);
      app.save(r);
    }
  } catch (_) {/* already gone */}
}

// Reconcile one note's children to the snapshot: upsert the snapshot's items /
// attachments and soft-delete any current child not present in the snapshot.
function reconcileChildren(app, ownerId, noteId, snapItems, snapAttachments) {
  const wantItems = {};
  for (const m of snapItems) { wantItems[m.id] = true; restoreItem(app, m); }
  const wantAtt = {};
  for (const m of snapAttachments) { wantAtt[m.id] = true; restoreAttachment(app, ownerId, m); }

  const curItems = app.findRecordsByFilter("checklist_items", "note = {:n}", "", 0, 0, { n: noteId });
  for (const c of curItems) if (c && !wantItems[c.id]) softDelete(app, "checklist_items", c.id);
  const curAtt = app.findRecordsByFilter("attachments", "note = {:n}", "", 0, 0, { n: noteId });
  for (const c of curAtt) if (c && !wantAtt[c.id]) softDelete(app, "attachments", c.id);
}

function groupByNote(rows) {
  const by = {};
  for (const m of rows || []) {
    (by[m.note] = by[m.note] || []).push(m);
  }
  return by;
}

// mode: "replace" (whole account → exactly this snapshot) or
//       "notes"   (only data.noteIds, others untouched).
function restoreSnapshot(app, ownerId, snapshotId, mode, noteIds) {
  const snap = app.findRecordById("snapshots", snapshotId);
  if (snap.getString("owner") !== ownerId) {
    throw new Error("not your snapshot");
  }
  // Always take a reversible safety snapshot of the current state first.
  buildSnapshot(app, ownerId, "pre-restore");

  const data = readSnapshotJson(app, snap);
  const itemsByNote = groupByNote(data.checklistItems);
  const attByNote = groupByNote(data.attachments);
  const noteIndex = {};
  for (const n of data.notes) noteIndex[n.id] = n;

  if (mode === "replace") {
    for (const m of data.notebooks || []) restoreNotebook(app, ownerId, m);
    for (const m of data.labels || []) restoreLabel(app, ownerId, m);
    for (const n of data.notes || []) {
      restoreNote(app, ownerId, n);
      reconcileChildren(app, ownerId, n.id, itemsByNote[n.id] || [], attByNote[n.id] || []);
    }
    // Trash anything that didn't exist in the snapshot.
    const wantNotes = {}; for (const n of data.notes || []) wantNotes[n.id] = true;
    const wantLabels = {}; for (const l of data.labels || []) wantLabels[l.id] = true;
    const wantNbs = {}; for (const b of data.notebooks || []) wantNbs[b.id] = true;
    for (const c of app.findRecordsByFilter("notes", "owner = {:o}", "", 0, 0, { o: ownerId }))
      if (c && !wantNotes[c.id]) softDelete(app, "notes", c.id);
    for (const c of app.findRecordsByFilter("labels", "owner = {:o}", "", 0, 0, { o: ownerId }))
      if (c && !wantLabels[c.id]) softDelete(app, "labels", c.id);
    for (const c of app.findRecordsByFilter("notebooks", "owner = {:o}", "", 0, 0, { o: ownerId }))
      if (c && !wantNbs[c.id]) softDelete(app, "notebooks", c.id);
    return { mode: "replace", notes: (data.notes || []).length };
  }

  // mode === "notes": selectively restore the chosen notes only.
  const ids = noteIds || [];
  for (const id of ids) {
    const n = noteIndex[id];
    if (!n) { softDelete(app, "notes", id); continue; } // didn't exist then
    // Referenced labels/notebook must exist so the relations resolve.
    for (const l of data.labels || []) {
      try { JSON.parse(n.labels || "[]").indexOf(l.id) >= 0 && restoreLabel(app, ownerId, l); } catch (_) {}
    }
    if (n.notebook) {
      const nb = (data.notebooks || []).find((b) => b.id === n.notebook);
      if (nb) restoreNotebook(app, ownerId, nb);
    }
    restoreNote(app, ownerId, n);
    reconcileChildren(app, ownerId, id, itemsByNote[id] || [], attByNote[id] || []);
  }
  return { mode: "notes", notes: ids.length };
}

module.exports = {
  DEFAULT_RETENTION_DAYS,
  intervalSeconds,
  isDue,
  fromPbTime,
  buildSnapshot,
  currentStats,
  latestSnapshot,
  runDueSnapshots,
  pruneAndSweep,
  sweepBlobs,
  restoreSnapshot,
};
