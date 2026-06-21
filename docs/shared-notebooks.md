# Shared notebooks — design

Let an **owner** share one of their notebooks with other registered users. Every
note inside a shared notebook is visible to all its members, and **all members
can create, edit, move and delete** the notes inside it. The **owner** alone
decides who it's shared with and can rename/delete the notebook.

This is the first feature that breaks the app's "everything is owner-scoped"
assumption, so most of the work is in the **backend access rules** and the
**sync/edit path**, not the UI.

## Decisions (locked)

| Area | Decision |
|---|---|
| **Platform** | **Server-connected only.** Works on web and on mobile *with a connected, signed-in server* (like Version history). No local-only / no-account equivalent. |
| **Editing** | Shared notes are editable **only while the server is reachable**. Offline (or server down) ⇒ shared notes are **read-only** (last-synced view). |
| **Membership** | Owner picks members from the server's **registered users** (a picker of emails). Added users **auto-join** — no invite/accept step. |
| **Who manages** | **Owner only** manages membership + can rename/delete the notebook. Managed **inline** from the shared-icon popup. |
| **Permissions** | Every member is an **editor**: create / edit / delete notes, and **move notes freely in and out** (moving a personal note in shares it). |
| **Attribution** | **None.** No per-note author tracking; just a "shared" indicator. |
| **Indicator** | A "shared" icon on **note cards** *and* in the **notebook selector**. Tapping it reveals the member list. |
| **On removal** | Notes a removed member created **stay in the notebook**; the person just loses access. |
| **Concurrency** | **Server-authoritative note-level lock** in a dedicated `note_locks` collection (UNIQUE on note → atomic acquire, one editor at a time), realtime, heartbeat + ~9 s auto-expire with a precise staleness timer. No manual take-over; no LWW backstop needed (the constraint prevents two holders). |

## Data model

### PocketBase (server)

**`notebooks`** — add:
- `sharedWith` — multi-relation → `users`. Owner-managed. Empty ⇒ private (today's
  behaviour). A user is a *member* iff they're the `owner` **or** appear in
  `sharedWith`.

**`note_locks`** (new collection) — the edit lock, one row per locked note:
- `note` — relation → `notes`, required, **UNIQUE** (cascade-delete). The
  uniqueness is what makes acquire atomic.
- `lockedBy` — relation → `users`. The current holder.
- `lockedAt` — text ISO timestamp, refreshed by the holder's heartbeat; used to
  expire stale locks.
- Member-scoped read/write (same predicate as the note). See *Concurrency*.

> The original plan put `lockedBy`/`lockedAt` directly on `notes`. Those columns
> still exist (migration left in place) but are **unused** — the lock moved to
> `note_locks` so it's decoupled from note content and atomic via the constraint.

`checklist_items` / `attachments` are unchanged — they inherit access from their
parent note (see rules).

### Access rules (the core change)

Today: `owner = @request.auth.id` everywhere. New predicate — a note is
**accessible** to the caller when they're its owner *or* a member of its
notebook:

```
// notes: list/view/create/update/delete
owner = @request.auth.id
  || note.notebook.owner = @request.auth.id
  || note.notebook.sharedWith.id ?= @request.auth.id
```

- **`notebooks`**: `view`/`list` if `owner = auth.id || sharedWith.id ?= auth.id`.
  **`update`/`delete`** stay **owner-only** — but the owner may edit `sharedWith`.
  (Members must *not* be able to change `sharedWith`, rename, or delete.)
- **`notes`**, **`checklist_items`**, **`attachments`**: read+write if the caller
  is a member of the parent note's notebook (predicate above, resolved through
  `note.notebook…` for children). Create is allowed when the target notebook is
  one you're a member of.
- A note with **no notebook** or a **private** notebook keeps today's pure
  owner-scoping — nothing changes for personal notes.

> Rule cost: PocketBase resolves `note.notebook.sharedWith` per request. Fine at
> this scale; revisit if it shows up in profiling.

### drift (mobile local DB)

- `notebooks`: add `sharedWith` as a JSON id-array string column (mirrors how
  `notes.labels` is stored locally). Migration `vN → vN+1`.
- `notes`: add `lockedBy` (text, nullable) + `lockedAt` (text, nullable).
- Local read views stay **not** owner-scoped (today's behaviour), so once a
  shared note is pulled onto the device it simply appears in the lists.

## Sync & the online-only edit path

Shared notes deliberately do **not** flow through the normal mobile offline
dirty-queue, because the whole point of "online-only editing" is to eliminate
offline divergence.

- **Pull (read):** unchanged in shape. Because the server rules now also return
  notes from notebooks you're a member of, the existing "pull records changed
  since cursor" loop brings shared notes (+ items/attachments) onto the device
  automatically. They render read-only when offline.
- **Write (edit):** shared-note **content edits go straight to the server** on
  mobile, not through the local-first DB + sync. The editor swaps in
  `OnlineSharedNoteRepository` (`data/online_shared_repository.dart`) for the open
  shared note, which overrides the high-frequency content writes (note title/body,
  checklist add/edit/check/delete/reorder) to write directly to PocketBase; the
  change comes back into the local DB via realtime, which feeds the (unchanged)
  read streams. So shared notes are server-authoritative and real-time on mobile
  just like on web — no local-first lag, no divergence. Low-frequency actions
  (color, pin, labels, attachments) keep the local-first path.
- **Server wins on reconnect:** if the phone made edits during a brief offline
  blip, on reconnect it `refetchNote()`s the open shared note (discarding those
  local edits and any local-only items) so it can't diverge from the server.
- **Membership change:** owner edits `notebooks.sharedWith`; LWW propagates. A
  newly-added member pulls the notebook + its notes on next sync/subscription. A
  **removed** member, on next sync, finds those records no longer readable → the
  client **purges** the now-inaccessible shared notebook + its notes from the
  local DB (they were never theirs to keep).

## Concurrency — the note lock (`note_locks`)

The lock is **server-authoritative** and lives in its own collection,
**`note_locks`** — one row per locked note, with a **UNIQUE index on `note`**.
Acquiring = **creating** that row, so the *database* arbitrates: if two members
open the same note at once, exactly one `create` succeeds and the other gets a
uniqueness conflict and stays read-only. No client-side duelling, no
last-write-wins races. Decoupled from the note record, so lock churn never
touches note content. Implemented client-side as `NoteLockController`
(`features/notes/note_lock_controller.dart`).

**Lifecycle** (all direct to the server — shared editing is online-only):
1. **Subscribe + ask the server.** Opening a shared note subscribes to its lock
   row over **realtime** and reads the current state; the editor stays read-only
   until the server answers (never a guess).
2. **Acquire = create the row** (`{note, lockedBy: me, lockedAt: now}`). On a
   uniqueness conflict it re-reads: if the existing lock is **stale**, it deletes
   and re-creates (takeover); otherwise it stays read-only.
3. **Heartbeat = update `lockedAt`** every **~3 s** while held.
4. **Release = delete the row** on close (dispose) — instant and reliable. Also
   on **app background** (screen lock / app switch), so others can edit
   immediately; re-acquired on foreground.
5. **Expiry (stale self-heal).** A lock older than **~9 s** (no heartbeat) is
   stale and may be taken over — covers crashes / abrupt disconnects. A **precise
   staleness timer** fires the takeover the moment it expires, so a viewer takes
   over in ~6–9 s rather than waiting for a poll. A **~6 s watchdog** + realtime
   reconnect re-subscribe are the fallbacks.

**Reachability.** `connectivity_plus` flips a shared note read-only **instantly**
on network loss (no waiting for the watchdog); the watchdog's own request (with a
4 s timeout) is the server-reachability check. An **abrupt** offline relies on
expiry for others to take over (the server can't be told the holder vanished); a
clean close / background releases instantly.

No "changed elsewhere" backstop banner is needed: the UNIQUE constraint prevents
two holders, so the acquire race it was meant to cover can't happen.

## Backend hooks (`server/pb_hooks/`)

1. **User picker / id resolution.** The `users` collection isn't listable by
   other users. Add an auth-gated route, e.g. `GET /api/noteesek/users`, that
   returns `[{id, email}]` for verified accounts so the owner can pick members
   (and so the client can resolve emails → ids for `sharedWith`). Excludes the
   caller; consider excluding existing members from the suggestions.
   **Decision: exposing every registered email to any signed-in user is
   accepted** (trusted self-hosted servers) — no extra gating for now.
No lock-acquire hook is needed — atomicity comes for free from the **UNIQUE
index on `note_locks.note`** (a compare-and-set hook was the original plan; the
constraint supersedes it).

## UI

- **Note card** (`note_card.dart`): a small people/share icon when the card's
  notebook is shared. (No author/attribution — just the indicator.)
- **Notebook selector** (`_NotebookSelector`): shared notebooks show the same
  icon next to their name.
- **Members popup** (tap the shared icon): lists members (avatars/initials +
  email). For the **owner**, the popup also has inline **add** (opens the
  registered-user picker) / **remove** controls. Members see it read-only.
- **Manage Notebooks** (`ManageNotebooksScreen`): a notebook row reflects shared
  state; delete still offers move-to-no-notebook or trash-notes (members lose
  access on delete).
- **Editor** (`note_editor_screen.dart`):
  - If the note's notebook is shared and the server is **unreachable** →
    read-only with *"Connect to your server to edit shared notes."*
  - If **locked by someone else** → read-only with *"<name> is editing…"*, live
    updates streaming in; becomes editable when released/expired.
  - On entering edit, acquire the lock + start the heartbeat; release on exit.

## Phasing — all shipped ✅

- **Phase 1 — Backend foundation.** `notebooks.sharedWith` + access rules for
  notebooks/notes/items/attachments; the `users` picker hook. Verified with a
  two-user API smoke test.
- **Phase 2 — Sharing UI.** Owner shares/unshares from the inline sheet +
  registered-user picker; shared indicator on note cards + selector; members
  sheet; Manage Notebooks share action.
- **Phase 3 — Online-only edit path + removal cleanup.** Shared notes are
  read-only when the server is unreachable; the sync engine reconcile step purges
  local shared notebooks (+ notes) once I'm unshared/removed.
- **Phase 4 — Locking.** Reworked from note-field LWW into the dedicated,
  server-authoritative **`note_locks`** collection (UNIQUE acquire, realtime,
  heartbeat/expiry, reliable release, background release, reconnect re-acquire,
  precise staleness takeover). See *Concurrency* above. The `notes.lockedBy` /
  `lockedAt` columns from the original approach are now unused (left in place).
- **Phase 5 — Real-time content + connectivity.** Shared-note content edits go
  **server-direct** on mobile (`OnlineSharedNoteRepository`) so they're real-time
  and non-divergent like web; `connectivity_plus` for instant offline; server-
  wins-on-reconnect (`refetchNote`).

## Deferred / explicitly out of scope

- **Viewer (read-only) role** — everyone is an editor for now.
- **Author attribution** / "who edited what".
- **Invite + accept** flow, shareable links, notifications.
- **Manual lock take-over** button (auto-expire is enough).
- **Conflicted-copy** safety net — unnecessary: shared editing is online-only and
  the lock is single-holder, so there's nothing to reconcile.
- **CRDT / real-time co-editing** (Google-Docs style) — doesn't fit PocketBase
  or the effort budget.
- **Offline editing** of shared notes — read-only offline by design.
