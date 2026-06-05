# Sync protocol

Noteesek is **offline-first**. The phone holds a local SQLite mirror (via
`drift`) and is fully usable with no network. Changes sync to PocketBase when a
connection is available, using **last-write-wins (LWW) per record**.

This document is the spec the Flutter sync engine implements. It is intentionally
simple — adequate for a single user editing across their own devices, where
concurrent edits to the *same* record are rare.

## Principles

1. **Local-first writes.** Every create/update/delete happens in local SQLite
   immediately and is reflected in the UI. The network is never on the critical
   path of a user action.
2. **The server is the source of truth for conflict resolution.** When two
   versions of a record disagree, the one with the newer `updated` timestamp
   wins. Ties are broken deterministically (see below).
3. **Deletes are soft.** Deleting sets `deleted = true` so the tombstone
   propagates to other devices. Hard purging happens later, server-side.
4. **Per-record granularity.** LWW is applied to whole records (a note, a
   checklist item, an attachment) — not individual fields.

## Local schema additions

Each synced row in local SQLite carries sync bookkeeping columns **not** sent to
the server:

| Column        | Meaning                                                        |
|---------------|----------------------------------------------------------------|
| `id`          | PocketBase record id (15-char). Generated locally if offline.\* |
| `dirty`       | `true` if the row has local changes not yet pushed.            |
| `updated`     | Last-known server `updated` (ISO-8601). Mirrors PocketBase.    |
| `deleted`     | Soft-delete flag (also a real server field).                  |

\* PocketBase ids are client-settable. The app generates a valid 15-char id
locally so a record created offline keeps the same id once pushed — no
id-remapping needed.

A single-row `sync_state` table holds the **pull cursor**:

| Column           | Meaning                                                |
|------------------|--------------------------------------------------------|
| `last_synced_at` | Server timestamp of the newest record seen on last pull. |

## A sync cycle

A sync runs on: app start, returning online, manual pull-to-refresh, and a
periodic timer. The cycle is **push, then pull**.

### 1. Push (local → server)

For each collection, select rows where `dirty = true`:

- **Created/updated** (`deleted = false`): `PUT` the record by id if it exists
  on the server, else `POST` with the local id. Send the full record. The
  server sets a fresh `updated`; store it locally and clear `dirty`.
- **Deleted** (`deleted = true`): push the record with `deleted = true` (a normal
  update). The tombstone now lives on the server. Clear `dirty`.

> LWW on push: if the server's `updated` is newer than what we based our edit
> on, the server still accepts our write (we're writing *now*, so our `updated`
> becomes newest). This is the "last writer wins" — whoever syncs last wins.
> Field-level merge is explicitly **not** done in v1.

### 2. Pull (server → local)

For each collection, fetch records changed since the cursor:

```
GET /api/collections/<name>/records
    ?filter=(updated > "{last_synced_at}")
    &sort=updated
    &perPage=200          # paginate until exhausted
```

For each incoming record, compare with the local row by `id`:

| Local state                     | Action                                              |
|---------------------------------|-----------------------------------------------------|
| missing                         | insert                                              |
| exists, **not** dirty           | overwrite with server version                       |
| exists, dirty, server `updated` > local `updated` | **server wins** — overwrite, drop local edit (LWW) |
| exists, dirty, server `updated` ≤ local `updated` | keep local; it will win on next push                |

Advance `last_synced_at` to the max `updated` seen. Incoming `deleted = true`
records are applied (the row is hidden/removed locally).

### Tie-breaking

If two `updated` timestamps are exactly equal, break the tie by comparing `id`
lexicographically (smaller id wins). This makes resolution deterministic across
devices without a central clock.

## Attachments

- On **push**, upload the file via multipart to the `attachments` collection
  (PocketBase stores it); store the returned filename locally.
- On **pull**, download lazily: fetch the file bytes the first time the note is
  opened/rendered, then cache on disk. Only metadata syncs eagerly.

## Ordering & integrity

- Push/pull **`notes` before `checklist_items` and `attachments`** so a child's
  `note` relation always resolves to an existing parent.
- A checklist item or attachment whose parent note is `deleted` is treated as
  deleted locally (the server cascade-deletes children on hard purge).

## What v1 deliberately omits

- Field-level / 3-way merge (a concurrent edit to the same note loses the older
  write entirely).
- Real-time updates (PocketBase realtime subscriptions) — pull is poll-based.
- Multi-device presence / live cursors.

These can be layered on later without changing the storage model.
