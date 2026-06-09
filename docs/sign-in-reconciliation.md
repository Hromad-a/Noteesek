# Sign-in reconciliation (design)

**Status:** ✅ implemented (all 4 phases). **Platform:** mobile only (web has no
local DB — sign-in there is just auth). Captured 2026-06-09.

Code: `features/auth/reconciliation_screen.dart`,
`sync/reconciliation_service.dart`, repo primitives `reownAll` /
`hasForeignLocalData` / `combineNotebooksByName`, `SyncEngine.syncOnce(pushOnly:)`,
wired in `login_screen.dart`. Tests: `test/sync_notebooks_repro_test.dart`
(integration) + `test/notes_repository_test.dart` (unit).

When a user signs into an account on a phone that already holds local data that
diverges from that account's server data, prompt them to choose how to reconcile
the two, instead of silently unioning. Destructive choices are guarded so data
isn't removed by accident.

## Decisions (locked)

1. **Keep local only = mirror.** Make the server exactly match the device: upload
   local data *and* delete server records that aren't local. Destructive to the
   server.
2. **Reconcile all local data, any owner.** Local rows owned by the offline
   `local` sentinel *or by a different account* are all in scope; Keep-local and
   Merge **re-own** them into the account being signed in (so you can move
   account A's notes into account B — with a clear warning).
3. **Same-name notebook combining: notebooks only, default OFF.** Merge offers a
   "Combine notebooks with the same name" toggle, default off (keep both). Notes
   are never name/title-merged (titles collide too easily).
4. **Guard = impact summary + type-to-confirm.** Destructive options show exact
   counts of what will be deleted and require typing a confirm word; the safe
   **Merge** option is preselected.

## When the prompt appears

Only on **sign-in**, and only when there is *foreign* local data to reconcile —
i.e. the local DB contains at least one note or notebook whose `owner` is **not**
the account being signed in (the `local` sentinel, or a different account). This
is a cheap local query, so the decision to prompt needs no server round-trip.

- Local DB empty, or all local data already owned by this account (a returning
  user reconnecting) → **no prompt**; proceed with the normal claim + sync
  (today's behaviour). Returning users are never nagged.
- Foreign local data present → fetch a server summary (counts + ids) and show the
  reconciliation screen before the first sync.

## The three strategies

Let **B** = the account signing in. "Local data" = every local row across notes,
checklist_items, attachments, labels, notebooks, regardless of owner.

| Option | Local result | Server result | Destructive? |
|--------|--------------|---------------|--------------|
| **Merge** (default) | union of both | union of both | no |
| **Keep local only** | unchanged (re-owned to B) | mirrors local | yes — server |
| **Keep server only** | replaced by server | unchanged | yes — local |

### Merge (keep all)
1. Re-own all local rows to B (`owner = B`, `dirty = true`) — claims offline and
   other-account data into B.
2. *If* "combine same-name notebooks" is on: build a name→notebook map across
   local + server; for each duplicate name keep the earliest-created (tie-break
   by id), reassign the others' notes to it, soft-delete the duplicates. Default
   off → pure union (two same-named notebooks coexist).
3. Normal sync (push local up, pull server down) → union on both sides.
4. Default-notebook reconciliation (existing `ensureDefaultNotebook`).

### Keep local only (mirror local → server)
1. Re-own all local rows to B (`owner = B`, dirty).
2. Push all local up (server `owner` forced to B by `owner.pb.js`).
3. **Mirror:** for each collection, soft-delete the server records whose ids are
   not present locally (`serverIds − localIds`). Tombstones propagate.
4. Settle with a normal sync.
   Result: server == local; the device's data is unchanged.

### Keep server only (replace local)
1. Wipe the local DB and reset all sync cursors (`wipeAllLocal`).
2. Full pull from the server (cursor empty).
   Result: local == server; local-only data is discarded.

## Impact summary (shown on the screen)

After auth, query the server for per-collection counts + ids and compare to local
(all owners):

- **Keep local only** → "Deletes **N** records from the server" where
  `N = |serverIds − localIds|`. (When the device holds a *different* account's
  data, this is typically *all* of B's current server data — surface that
  prominently.)
- **Keep server only** → "Deletes **M** records from this device, including
  **X** that aren't on the server" where `M = |localIds|`, `X = |localIds −
  serverIds|` (X = what's permanently lost).
- **Merge** → "Combines **A** local + **S** server records" (nothing deleted).

## UI & flow

A dedicated **`ReconciliationScreen`** (full screen, not a dialog — too much
content), pushed from the login flow after `authWithPassword` succeeds and before
any sync, when the trigger fires:

```
You have data on this device to reconcile.
  This device:   A notebooks · B notes   (C from another account / offline)
  This account:  D notebooks · E notes   (on the server)

( ) Merge — keep everything from both            [recommended, preselected]
       [ ] Combine notebooks with the same name
( ) Keep this device only — make the server match this device
       ⚠ Deletes N records from the server.   [type REPLACE to enable]
( ) Keep the server only — replace this device's data
       ⚠ Deletes M records here (X not on the server).  [type REPLACE to enable]

                                   [ Cancel ]   [ Continue ]
```

- **Merge** is preselected; **Continue** is enabled for it immediately.
- Selecting a destructive option reveals a type-to-confirm field; **Continue**
  stays disabled until the confirm word matches.
- **Cancel** signs back out (no data touched) — sign-in is not completed until a
  choice is made, so the user can never half-apply a strategy by backing out.
- A progress state while the chosen strategy runs (mirror/replace can take a few
  seconds), then drop into the notes screen.

### Login-flow integration (`login_screen.dart`)
After `authWithPassword`:
1. `activeOwner = B`.
2. If **no** foreign local data → `claimLocalNotes(B)` + normal sync (unchanged).
3. Else → fetch server summary → push `ReconciliationScreen` → run the chosen
   strategy → then proceed to the notes screen.

Gate the whole feature on `!kIsWeb`.

## Implementation surface

- `features/auth/reconciliation_screen.dart` — the chooser UI + type-to-confirm
  guard + progress.
- `sync/reconciliation_service.dart` — the three strategies + the server summary
  fetch. Holds a `NotesRepository`/`AppDatabase` + `PocketBase` + `SyncEngine`.
  - `Future<ReconcileSummary> inspect()` — local vs server counts/ids.
  - `Future<void> merge({bool combineSameName})`
  - `Future<void> keepLocalMirror()`
  - `Future<void> keepServerReplace()`
- `local_notes_repository.dart` — a `reownAll(String userId)` (generalises
  `claimLocalNotes` to *all* local rows, not just the `local` sentinel) and a
  `combineNotebooksByName(...)` helper.
- `sync_engine.dart` — a server-summary/ids fetch + a "soft-delete server ids"
  helper for the mirror path (reuses the existing resilient push/pull).
- `login_screen.dart` — the branch above.

## Edge cases & risks

- **Re-owning another account's data is a real move**, not a copy: after Merge or
  Keep-local, account A's notes belong to B. The warning copy must say so.
- **Keep-local when the device holds a different account** deletes *all* of B's
  current server data (none of it is local). The impact count makes this explicit;
  the type-to-confirm is the backstop.
- **Interrupted runs** (network drop mid-mirror): each strategy must be safe to
  re-run. Re-own is idempotent; push/pull are idempotent (per the sync
  invariants); server-extra soft-deletes are idempotent. A retry resumes cleanly.
- **Default notebook**: both sides have one (`is_default`, named "Notebook").
  Merge with combine-off still reconciles defaults via the existing is_default
  logic (independent of the name toggle), so you don't end up with two defaults.
- **Large datasets**: summary id-fetch and mirror deletes must paginate.
- **`watchHasPending`** isn't owner-scoped; after re-own everything is B's, so the
  indicator is correct. (Pre-existing other-account dirty rows are re-owned too.)

## Testing (integration, against the live backend)

- Merge → union; combine-same-name on → one notebook per duplicate name, notes
  preserved; combine off → both kept.
- Keep-local mirror → server == local; server-only records soft-deleted; local
  intact and re-owned.
- Keep-server replace → local == server; local-only records gone.
- Trigger logic: prompt only when foreign local data exists; skipped for a
  returning same-account user.
- Guard widget test: destructive Continue disabled until the confirm word matches.

## Phasing (this is the largest roadmap item)

1. ✅ Detection + `ReconciliationScreen` shell + **Merge** path (re-own + union),
   wired into login.
2. ✅ **Keep server only** (replace) + impact count + type-to-confirm guard.
3. ✅ **Keep local only** (mirror, push-only + server-side soft-deletes) + guard.
4. ✅ **Combine same-name notebooks** toggle (default off).
5. ✅ Integration tests for each strategy + unit tests for the primitives.

Not done: a widget test for the guard (the type-to-confirm gating) — covered by
manual/analyzer for now.
