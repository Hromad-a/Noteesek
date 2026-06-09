# Sync protocol

> **Applies to the mobile (Android) client only.** The web client is online and
> server-backed — it reads/writes PocketBase directly with realtime updates and
> has no local store or sync. See [CLAUDE.md](../CLAUDE.md).

The **mobile** client is **offline-first**. The phone holds a local SQLite mirror
(via `drift`) and is fully usable with no network. When a server is connected,
changes sync to PocketBase using **last-write-wins (LWW) per record**.

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
    ?filter=(updated >= "{last_synced_at}")   # inclusive — see invariants below
    &sort=updated,id                          # deterministic order (tie-break by id)
    &perPage=200                              # paginate until exhausted
```

For each incoming record, compare with the local row by `id`:

| Local state                     | Action                                              |
|---------------------------------|-----------------------------------------------------|
| missing                         | insert                                              |
| exists, **not** dirty           | overwrite with server version                       |
| exists, dirty, server `updated` > local `updated` | **server wins** — overwrite, drop local edit (LWW) |
| exists, dirty, server `updated` ≤ local `updated` | keep local; it will win on next push                |

Advance `last_synced_at` over the **contiguous successfully-applied prefix**.
Incoming `deleted = true` records are applied (the row is hidden/removed locally).

#### Reliability invariants (why the query is shaped this way)

- **Inclusive boundary.** The filter is `updated >= last_synced_at`, *not* `>`.
  A strict `>` permanently skips any record the server stamps with the exact
  cursor timestamp (same millisecond as the previous pull's newest record).
  Re-pulling boundary records is safe because apply is **idempotent**
  (insert-or-update keyed by `id` + the LWW check above).
- **Deterministic order.** Sort is `updated,id` (not `updated` alone) so
  pagination is stable when timestamps tie — otherwise a record can fall between
  page boundaries and be missed.
- **Per-record isolation.** One record that fails to apply does not abort the
  rest, and the cursor only advances over the contiguous applied prefix, so a
  failed record (and anything after it) is retried next cycle, never skipped.
- **Per-collection isolation.** Each collection's push/pull is an independent
  step. A non-connectivity error in one collection is logged and skipped so it
  can't strand the others; a connectivity error aborts the cycle and surfaces
  the offline state.
- **Attachment bytes are retried cursor-independently.** A protected file whose
  bytes failed to download is re-fetched on a later cycle by a dedicated pass
  (it wouldn't reappear under the `updated` cursor once its metadata synced).

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

- Push/pull **`labels` and `notebooks` before `notes`**, and **`notes` before
  `checklist_items` and `attachments`**, so a note's `labels`/`notebook`
  relations and a child's `note` relation always resolve to an existing record.
- A checklist item or attachment whose parent note is `deleted` is treated as
  deleted locally (the server cascade-deletes children on hard purge).

## Server-side safeguards

The server is the authority, so it enforces invariants the client could
otherwise get wrong (`server/pb_hooks/`, `server/pb_migrations/`):

- **Owner is stamped server-side on create** (`owner.pb.js` + migration
  `1700000011`). For `notes`, `labels`, and `notebooks`, an
  `onRecordCreateRequest` hook forces `owner = @request.auth.id` regardless of
  what the client sent, removing the "record created locally but never syncs up"
  failure mode caused by a stale/empty client owner (e.g. the offline `local`
  sentinel). Because PocketBase checks the `createRule` *before* the hook, the
  createRule is relaxed to `@request.auth.id != ""` (authenticated) so the hook
  can take over ownership; list/view/update/delete rules stay owner-scoped, so
  access is unchanged.
- **All app collections are owner-scoped** by collection rules
  (`owner = @request.auth.id`, or `note.owner` for children), so a pull only ever
  returns the caller's own records and a write can only touch them.
- **Indexes for incremental pulls.** Every synced collection has an index on
  `updated` (composite `(owner, updated)` for notes/labels/notebooks; a plain
  `updated` index on checklist_items/attachments) so `updated >= cursor` pulls
  stay efficient as data grows.
- `created`/`updated` are server-managed `autodate` fields; the client never
  sets them, so the LWW timestamp can't be forged.

## Notebooks & the default notebook

A note belongs to **exactly one** notebook (`notes.notebook`, a single relation).
Notebooks sync as ordinary owner-scoped, soft-deletable records (LWW like
everything else). An empty or unknown `notebook` value resolves to the user's
**default notebook** on the client, so a note never disappears if its notebook
was deleted before it was reassigned.

Each user has one default notebook (`is_default = true`, named "Notebook",
rename-only). Because a device can create a local default offline *and* later
pull the account's existing default, duplicate defaults are possible briefly.
They are reconciled deterministically: the **earliest-created** default (tie-broken
by `id`) is kept and the rest are soft-deleted. Every device makes the same
choice, so they converge.

## What v1 deliberately omits

- Field-level / 3-way merge (a concurrent edit to the same note loses the older
  write entirely).
- Real-time updates (PocketBase realtime subscriptions) — pull is poll-based.
- Multi-device presence / live cursors.

These can be layered on later without changing the storage model.
