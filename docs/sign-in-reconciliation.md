# Sign-in reconciliation (design)

**Status:** ✅ implemented. **Platform:** mobile only (web has no local DB —
sign-in there is just auth). Captured 2026-06-09; simplified 2026-06-11.

Code: `features/auth/reconciliation_screen.dart`,
`sync/reconciliation_service.dart`, repo primitives `claimLocalNotes` /
`hasForeignAccountData`, wired in `login_screen.dart`. Tests:
`test/sync_notebooks_repro_test.dart` + `test/reconcile_cross_account_repro_test.dart`
(integration) + `test/notes_repository_test.dart` (unit).

## The model (deliberately simple)

A note's `owner` records who created it: the offline `local` sentinel before any
server is connected, otherwise a user id. The backend is a single PocketBase
where **record ids are globally unique across all users** (one shared table per
collection, scoped by `owner`). That fact drives the whole design: an id that
belongs to account A **cannot** be taken over by account B (B's update is hidden
→ 404, and a create collides → 400). So we do **not** try to move/merge data
between two accounts on the same server.

There are exactly two cases at sign-in:

1. **Offline / same-account data only** — the device holds only `local`-owned
   rows (made offline) and/or rows already owned by the account signing in. This
   is the normal path: [`claimLocalNotes`](../app/lib/data/local_notes_repository.dart)
   re-owns the `local` rows to the account (in place — their ids were never on
   the server) and a normal sync pushes them up. **No prompt.**

2. **Another account's data is present** — the device holds non-deleted
   notes/notebooks owned by a *different* account (e.g. you used account A, signed
   out, and are now signing into account B). Detected by
   [`hasForeignAccountData`](../app/lib/data/local_notes_repository.dart) (owner
   ≠ this user **and** ≠ `local`). We can't merge across accounts, so the
   `ReconciliationScreen` offers a single guarded action:

   **Replace this device with the server** — [`keepServerReplace`](../app/lib/sync/reconciliation_service.dart):
   `wipeAllLocal()` (clears every table + sync cursors) then a full pull of the
   signed-in account. Everything on the device — including any never-synced
   offline notes — is discarded; the device ends up mirroring the account.

   The screen shows a before/after summary (what's discarded vs. loaded) and a
   type-`REPLACE`-to-confirm gate. **Cancel** undoes the sign-in (clears auth,
   resets the active owner to `local`) and leaves the device untouched.

## Moving notes between accounts

There is no in-app merge for this. The supported path is **export then import**:
the importer (`features/import/`, and JSON backup restore) creates fresh ids and
stamps the importing account as owner, so it never collides. Export from account
A, sign into B, import — you get independent copies under B while A keeps its
originals.

## Why the old multi-strategy design was removed

The earlier version offered Merge / Keep-local-mirror / Keep-server-replace and
tried to reconcile another account's data by re-owning (then, after a bug fix,
re-id-copying) it. That was error-prone precisely because of the shared-table /
global-id reality above: re-owning stranded rows as permanently-dirty, and the
re-id workaround silently duplicated data on round-trips. Collapsing to
"claim-local, else wipe-and-pull" removes the cross-account conflict surface
entirely; cross-account moves are handed off to export/import, which is
collision-free by construction.

## Edge cases

- **Returning user, clean device** (all rows already this account, or empty) →
  case 1, no prompt, normal sync.
- **Local + foreign-account data mixed** → case 2; the wipe discards the
  local-only notes too. Users are told to export first if they want to keep them.
- **Interrupted wipe/pull** → safe to re-run: `wipeAllLocal` is idempotent and a
  fresh pull (empty cursors) re-fetches everything.
- **Web** → never reaches reconciliation; `hasForeignAccountData` is always false
  (no local DB) and sign-in is pure auth.
