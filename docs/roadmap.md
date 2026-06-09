# Noteesek roadmap

Planned work and the decisions behind it. Captured 2026-06-09. Keep this in sync
as items ship (move them to "Shipped" with the commit/tag).

## Shipped this round (fixes)

- **Pull-to-refresh sync** — swipe down on the notes grid forces a sync (mobile;
  passthrough on web). `notes_screen.dart`.
- **Sync resilience** — `syncOnce` runs each collection's push/pull as an
  independent step, so one collection's data/API error can't strand the others
  (was the likely cause of "notebooks sync up but never pull back to a fresh
  device"). Connectivity errors still abort + show offline. `sync_engine.dart`.
- **Claim local labels on sign-in** — `claimLocalNotes` now re-owns offline
  labels too (previously only notes + notebooks), so labels created offline
  actually sync up. `local_notes_repository.dart`.
- **Password-reset link keeps its port** — when `APP_URL` is pinned, the literal
  value is baked into the reset email template instead of the `{APP_URL}`
  placeholder (PocketBase normalizes the stored appURL and drops the port).
  `server/pb_hooks/smtp.pb.js`. *(Set `APP_URL` in `.env` to your public origin;
  unset = auto-derived from the request origin, which is why it showed
  `localhost` in local testing.)*
- Regression: `test/sync_notebooks_repro_test.dart` (integration) — fresh-device
  notebook pull + sign-in reconciliation race.

## Known limitations

- **Web password-manager autofill** — login fields already carry `AutofillGroup`
  + correct `autofillHints` (works on Android). On Flutter web (CanvasKit) there
  are no real DOM `<input>`s for managers to detect; no reliable fix on current
  Flutter. Revisit if Flutter ships better web semantics/input handling.

## Features — ✅ all shipped (2026-06-09)

All of the items below (reconciliation + 1–8) are implemented. They need a
web/APK rebuild to run on a device. Details kept for reference.

### 0. Sign-in reconciliation — ✅ DONE — see [sign-in-reconciliation.md](sign-in-reconciliation.md)
On sign-in, when the device holds local data that diverges from the account's
server data, prompt to **Merge** (union; optional combine-same-name notebooks),
**Keep local only** (mirror local → server), or **Keep server only** (replace
local). Reconciles data of any owner (re-owns offline/other-account data into the
account); destructive choices show impact counts + require type-to-confirm.
Mobile only. All 4 phases shipped.

### 1. Undo (delete-to-trash) — ✅ DONE
Snackbar **Undo** after a note (single or bulk selection) is sent to Trash;
restores the exact ids. No schema change. *Decision: scope = delete-to-trash
only.*

### 2. Per-label colors — ✅ DONE
Add `color` to the `labels` collection (PB migration) + a `labels.color` drift
column (schema bump + migration; rides label LWW sync). Color picker on
`ManageLabelsScreen` and at create-time; apply on the drawer filter chips, note
cards, and the label sheet. Reuses the curated palette.

### 3. App lock — biometric + PIN — ✅ DONE
Packages: `local_auth` + `flutter_secure_storage` (hashed PIN). Settings: enable
lock, set/change PIN, toggle biometric. A lock gate wraps the app and re-locks on
resume from background (lifecycle observer). *Decision: biometric + PIN, whole
app. Web: N/A.*

### 4. Full JSON backup/restore — ✅ DONE
Serialize **all** drift tables (notes, items, attachments as base64, labels,
notebooks) + a schema-version header to one file (share/save). Restore re-imports
**preserving ids/timestamps** (upsert by id, mark dirty to re-sync) — distinct
from Markdown import which mints new ids. Settings → Data & storage. *Decision:
full JSON backup (lossless).*

### 5. Markdown — render + toolbar — ✅ DONE
Settings toggle `markdownEnabled` (persisted, like the theme). When on: note
bodies **render** Markdown in the card preview + a read view (`markdown_widget`;
`flutter_markdown` is discontinued), and the editor gets a **toolbar**
(bold/italic/heading/list/link) that inserts Markdown around the selection.
Editing stays plain text underneath; export already emits Markdown. *Decision:
render + toolbar.*

### 6. Quick capture — Share-to-Noteesek (Android) — ✅ DONE
`receive_sharing_intent` + manifest `SEND`/`SEND_MULTIPLE` intent filters (text +
images). Shared text → new text note; shared image(s) → new note with
attachment(s); opens for a quick edit. Android-only. *Decision: share-intent
receive (not widget / not notification).*

### 7. Onboarding + empty-state polish — ✅ DONE
First-run flag → a one-time intro carousel (offline-first / optional sync on
mobile; login on web). Polish empty notes/archive/trash/search states (copy,
illustration, quick actions). On mobile with no server connected, a dismissible
"Connect a server to sync" card on the empty state. *Decision: all three.*

### 8. Sign out everywhere — ✅ DONE
PocketBase JWTs are stateless (no device list). A custom auth-required hook route
(e.g. `POST /api/noteesek/logout-everywhere`) rotates the user's `tokenKey`,
invalidating every existing token on all devices; the current client re-auths.
Button in Settings (web + mobile). *Decision: "sign out everywhere" only — no
per-device tracking.*

## Deferred / ideas (from CLAUDE.md)
Release-signed APK, iOS, FTS5 search, reminders, HTTPS (then tighten cleartext).
