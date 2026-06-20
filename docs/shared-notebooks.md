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
| **Concurrency** | **Pessimistic note-level lock** (one editor at a time) + heartbeat + auto-expire. **No** manual take-over. Backstop for rare races: **last-write-wins + a "changed elsewhere" banner**. |

## Data model

### PocketBase (server)

**`notebooks`** — add:
- `sharedWith` — multi-relation → `users`. Owner-managed. Empty ⇒ private (today's
  behaviour). A user is a *member* iff they're the `owner` **or** appear in
  `sharedWith`.

**`notes`** — add lock fields (note-level pessimistic lock):
- `lockedBy` — relation → `users`, nullable. Who currently holds the edit lock.
- `lockedAt` — autodate/text timestamp, nullable. Refreshed by the holder's
  heartbeat; used to expire stale locks.

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
- **Write (edit):** a shared-note edit takes the **online path** — it requires
  reachability, holds the lock, and writes straight to the server (optimistic
  local update + immediate server write). It is **not** queued as an offline
  dirty row. If the server is unreachable, the editor is read-only and the write
  is refused up front.
- **Membership change:** owner edits `notebooks.sharedWith`; LWW propagates. A
  newly-added member pulls the notebook + its notes on next sync/subscription. A
  **removed** member, on next sync, finds those records no longer readable → the
  client **purges** the now-inaccessible shared notebook + its notes from the
  local DB (they were never theirs to keep).

## Concurrency — the note lock

Pessimistic, **note-level**, advisory lock. One editor at a time per note.

**Lifecycle**
1. **Acquire on edit.** Opening a shared note for editing sets `lockedBy = me`,
   `lockedAt = now` — *if* the note is currently unlocked or the existing lock is
   **expired** (see below). Realtime broadcasts the change.
2. **Others go read-only.** Members viewing/holding that note flip to read-only
   with a badge: *"Sarah is editing…"*. Via realtime they can watch her changes
   stream in live.
3. **Heartbeat.** While the editor is open, the holder refreshes `lockedAt` every
   **~20–30 s**.
4. **Expiry (stale-lock self-heal).** A lock whose `lockedAt` is older than
   **~2 min** is considered **expired**; any member may then acquire it. This is
   what rescues crashes / disconnects / "left it open and walked away". **No**
   manual take-over button (deemed overkill).
5. **Release.** On save / close / navigate-away (and best-effort on realtime
   disconnect), clear `lockedBy`/`lockedAt`. Realtime re-enables editing for the
   next person.

**Backstop (rare races).** Two ways a lock can be bypassed: a same-instant
acquire race, or a takeover of an *expired* lock that overlaps the previous
holder's final save. For those:
- **Last-write-wins** decides what persists (last save by `updated`), and
- the loser's open editor shows a **"This note was changed by someone else —
  Reload / Keep mine"** banner (non-destructive) so nothing is lost silently.

Granularity note: checklist *items* are separate records, so the lock is only
about the one note as a unit; we do **not** lock individual items.

## Backend hooks (`server/pb_hooks/`)

1. **User picker / id resolution.** The `users` collection isn't listable by
   other users. Add an auth-gated route, e.g. `GET /api/noteesek/users`, that
   returns `[{id, email}]` for verified accounts so the owner can pick members
   (and so the client can resolve emails → ids for `sharedWith`). Excludes the
   caller; consider excluding existing members from the suggestions.
   **Decision: exposing every registered email to any signed-in user is
   accepted** (trusted self-hosted servers) — no extra gating for now.
2. **(Optional) Atomic lock acquire.** A `POST …/notes/{id}/lock` compare-and-set
   could make acquisition race-free. Given the **LWW + banner** backstop is
   accepted, this is **optional** — we can acquire optimistically client-side and
   let the backstop cover the rare race. Spec it as a later hardening step.

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
  - Backstop banner as described under Concurrency.

## Phasing

- **Phase 1 — Backend foundation.** ✅ Done. `notebooks.sharedWith` + lock fields
  migrations; access rules for notebooks/notes/items/attachments; the `users`
  picker hook. Verified with a two-user API smoke test.
- **Phase 2 — Sharing UI.** ✅ Done. Owner shares/unshares from the inline sheet +
  registered-user picker; shared indicator on note cards + selector; members
  sheet; Manage Notebooks share action. `sharedWith` + locks plumbed through both
  repos + the mobile sync engine (drift v9→v10).
- **Phase 3 — Online-only edit path + removal cleanup.** ✅ Done. Shared notes are
  read-only when the server is unreachable; the sync engine reconcile step purges
  local shared notebooks (+ notes) once I'm unshared/removed.
- **Phase 4 — Locking.** ✅ Done (core). `lockedBy`/`lockedAt` lifecycle in the
  editor: acquire on edit, ~25s heartbeat, ~2min auto-expire, release on close;
  others get a read-only editor with a "<email> is editing" / offline banner.
  Backstop is plain **LWW**; the explicit "changed elsewhere" banner for the rare
  expired-takeover race is **deferred** (the lock makes that case very rare).
- **Phase 5 (optional hardening).** Not started. The "changed elsewhere" banner;
  atomic lock-acquire hook; title-vs-body auto-merge; field-level niceties.

## Deferred / explicitly out of scope

- **Viewer (read-only) role** — everyone is an editor for now.
- **Author attribution** / "who edited what".
- **Invite + accept** flow, shareable links, notifications.
- **Manual lock take-over** button (auto-expire is enough).
- **Conflicted-copy** safety net — unnecessary given online-only editing + the
  LWW/banner backstop.
- **CRDT / real-time co-editing** (Google-Docs style) — doesn't fit PocketBase
  or the effort budget.
- **Offline editing** of shared notes — read-only offline by design.
