# Noteesek — project memory

Self-hosted, Google Keep–style notes. **Two clients, one Flutter codebase**, one
PocketBase backend. See `PLAN.md` for the original design narrative; this file is
the current source of truth.

## Platform model (important)

The same Flutter app behaves differently by platform:

- **Android (mobile): local-first.** Works fully offline with **no account**.
  Notes live in a local SQLite (drift) DB. A server is **optional** — connecting
  one enables **sync** (last-write-wins). Opens straight to notes (no login gate).
- **Web: online, server-backed.** **Login required** (registration allowed). No
  local DB and no sync engine — every read/write hits the PocketBase API
  directly, kept live with **realtime subscriptions**. If the server is
  unreachable, the UI shows an error (no offline on web). The web app is served
  *by* the server itself (PocketBase `pb_public`) and defaults its server URL to
  its own origin.

The split is implemented with `kIsWeb` branches + a repository interface.

## Architecture

```
Noteesek/
├── docker-compose.yml       # production deploy (pulls the published image)
├── docker-compose.build.yml # dev: extends ^ + builds the image from source
├── .env.example       # version/port + optional superuser & SMTP (copy to .env)
├── server/            # PocketBase backend (Docker)
│   ├── Dockerfile         # multi-stage: builds Flutter web -> serves from pb_public
│   │                      #   bakes in pb_migrations + pb_hooks + entrypoint.sh
│   └── pb_migrations/     # collections + schema as code (committed)
├── pb_data/           # runtime state (gitignored; back up by copying)
├── app/               # Flutter client (Android + web)
│   └── lib/
│       ├── app.dart            # MaterialApp; web = login-gated, mobile = local-first
│       ├── main.dart           # ProviderScope + SharedPreferences
│       ├── providers.dart      # prefs, db, pocketbase, auth, activeOwner
│       ├── config/app_config.dart
│       ├── data/
│       │   ├── notes_repository.dart        # ABSTRACT interface + Riverpod providers
│       │   ├── local_notes_repository.dart  # drift impl (mobile)
│       │   ├── remote_notes_repository.dart # PocketBase + realtime impl (web)
│       │   └── local/database.dart          # drift schema (NoteRow/ChecklistItemRow/AttachmentRow)
│       ├── sync/               # sync_engine.dart + sync_controller.dart (MOBILE ONLY)
│       └── features/
│           ├── auth/login_screen.dart       # connect (mobile) / login gate (web)
│           └── notes/                        # notes_screen, note_editor, note_card,
│                                             # archive_screen, trash_screen
│       └── web/                # index.html + sqlite3.wasm + drift_worker.js (web drift assets)
└── docs/sync-protocol.md
```

### Data layer
- `NotesRepository` (abstract, in `notes_repository.dart`) is the UI-facing API.
  Both impls speak in the **drift row models** (`NoteRow`, `ChecklistItemRow`,
  `AttachmentRow`) so widgets are platform-agnostic.
- `notesRepositoryProvider` returns `RemoteNotesRepository` on web, else
  `LocalNotesRepository`. **drift and the sync engine are never instantiated on
  web.**
- Riverpod stream providers (`activeNotesProvider`, `checklistItemsProvider`,
  `attachmentsProvider`, etc.) wrap the repo streams for the UI.

### Backend (PocketBase v0.39, single binary)
Collections, all **owner-scoped** (`owner = @request.auth.id`, or `note.owner`
for children):
- `notes`: type (text|checklist), title, body, pinned, archived, **color**,
  **labels (multi-rel → labels)**, deleted, created, updated
- `checklist_items`: note (rel), text, checked, position, deleted, …
- `attachments`: note (rel), **file (protected)**, deleted, … (image bytes)
- `labels`: name, deleted, created, updated (user tags; assigned via
  `notes.labels`, stored locally as a JSON id array string)
- `notebooks`: name, deleted, created, updated (a note belongs to **at most one**
  notebook; an empty/unknown `notes.notebook` means **no notebook**, i.e.
  uncategorized — there is no default notebook)

Protected files require a short-lived token (`pb.files.getToken()`) to download.
`created`/`updated` are autodate; `updated` drives last-write-wins sync. Labels
and notebooks sync first each cycle so a note's `labels`/`notebook` relations
resolve server-side.

### Sync (mobile only) — see docs/sync-protocol.md
Last-write-wins per record. Local rows carry `dirty` + `updated`. Push dirty
rows (parents before children) via update-or-create on the client-generated id;
pull records changed since a per-collection cursor; soft-delete tombstones
(`deleted=true`) propagate, hard delete on "delete forever". Connectivity errors
are non-fatal: `SyncController` tracks `reachable` and surfaces a "server not
responding" indicator + snackbar.

## Conventions
- IDs: 15-char PocketBase-compatible, generated client-side (`local/ids.dart`
  `newPbId()`), so offline-created records keep their id after upload.
- Timestamps: `pbNow()` → PocketBase-style ISO string that sorts
  lexicographically (used for LWW + filters).
- Deletes are soft (`deleted=true`); Trash is manual-purge only (no auto-delete).
- Local note owner sentinel = `'local'` (AppConfig.localOwner) until a server is
  connected, then notes are "claimed" (owner → user id) and synced.

## Features (current)
Multi-user auth · offline-first mobile + optional sync · web online/realtime ·
text + checklist notes · pin · **archive** (drawer) · **trash** (restore /
delete-forever / empty) · image attachments (protected) · offline substring
search (title/body/checklist) · **note colors** (curated themed palette,
`note_colors.dart`) · **labels** (create/assign/filter via drawer, manage on
`ManageLabelsScreen`) · **notebooks** (optional, at-most-one-per-note
collections; "All notes" / "No notebook" / per-notebook scopes via the grid
bottom-bar selector, manage on `ManageNotebooksScreen`) ·
**account settings** (change password / server URL / sign out) · **Markdown
export** (bulk: all active+archived notes → one zip of `notes/*.md` +
`attachments/*`, share sheet on mobile / download on web) · **single-note
share/export** (Markdown / plain text / PDF, from the editor overflow) ·
**import** (Markdown export zip + loose `.md`, and Google Keep Takeout) ·
**search filters** (notebook / labels / color / type / has-image) ·
**light/dark/system theme** (Settings → Appearance) · **checklist** drag-reorder
+ optional auto-sort-checked-to-bottom · **undo** delete-to-trash · **per-label
colors** · **app lock** (biometric + PIN, mobile) · **full JSON backup/restore**
(mobile, lossless) · optional **Markdown** rendering + editor toolbar · **quick
capture** (Android share-to-Noteesek) · **first-run onboarding** + connect-server
nudge · **sign out of all devices** · **pull-to-refresh** sync (mobile) ·
**sign-in reconciliation** (merge / keep-local / keep-server; see
docs/sign-in-reconciliation.md) · empty notes auto-move to Trash on close.

### Notebooks (`features/notes/`)
- A note belongs to **at most one** notebook (`notes.notebook`). There is **no
  default notebook**: an empty/unknown notebook means "no notebook"
  (uncategorized). The grid selector scope is one of `kAllNotes` (`''`, the
  default — show everything), `kNoNotebook` (uncategorized only), or a notebook
  id. `noteInScope()` implements the filter; grid/archive/trash/search all honour
  the scope (provider-level filtering in `notes_repository.dart`).
- `selectedNotebookIdProvider` (persisted) + `activeNotebookIdProvider` (collapses
  a stale id to `kAllNotes`) drive the filtering; `notebooksProvider` exposes the
  list. New notes from "All notes"/"No notebook" are uncategorized; from a
  notebook scope they inherit it.
- Switch/create lives in the bottom-bar `_NotebookSelector`; every notebook is
  rename/delete-able on `ManageNotebooksScreen` (delete offers move-to-no-notebook
  or trash-notes). The note editor's overflow menu has "Move to notebook" (with a
  "No notebook" option). The old default-notebook machinery was removed; the
  `is_default` column is dropped by a drift v7→v8 migration + the
  `1700000013_drop_notebook_default.js` PocketBase migration (both also empty the
  old default notebook out to "no notebook").

### Markdown export (`features/export/`)
- `markdown_export.dart` — pure renderer: YAML frontmatter (title, labels,
  notebook, color, pinned, timestamps) + heading + body; checklists as
  `- [ ]/[x]` task lists; images as `![](attachments/<id>.jpg)`. Unit-tested,
  no I/O.
- `export_service.dart` — `NoteExportService.buildZip()` gathers notes/items/
  attachments/labels/notebooks via the repo (`.first` on the streams) and zips
  with `archive`. Trashed notes excluded.
- `export_delivery.dart` — platform delivery via conditional import:
  `_io` (share_plus) / `_web` (blob + anchor download) / `_stub`. `deliverBytes`
  generalises it (any mimeType) for the single-note exports.
- Triggered from the drawer "Export notes" row.
- **Single-note export** (`single_note_export.dart`): editor overflow "Share /
  export" → Markdown (bare `.md`, or md+attachments zip when it has images),
  plain text (`note_plaintext.dart`), or PDF (`note_pdf.dart`, `pdf` pkg,
  delivered cross-platform via `printing`). The PDF renders the body **as
  Markdown** (`markdown_pdf.dart` maps the `markdown` AST → `pdf` widgets:
  headings, emphasis, lists, quotes, code, rules) and draws checklist boxes. It
  bundles Roboto latin+latin-ext (`assets/fonts/`, loaded by `pdf_fonts.dart`) so
  Unicode like Czech diacritics renders — the built-in WinAnsi fonts can't.

### Import (`features/import/`)
- Settings → Data & storage → "Import notes" → pick a source (Markdown / Google
  Keep), then a file (`file_picker`, `withData`). Runs on mobile **and** web.
- `markdown_import.dart` — reverses the exporter: parses YAML frontmatter,
  resolves `attachments/<id>` links from the zip, detects checklists
  (task-list-only). Loose `.md` → title from first H1 or filename.
- `keep_import.dart` — parses a Keep Takeout zip: active+archived (skips
  trashed); labels→labels, Keep color→nearest palette key, pinned/archived,
  annotations→body "Links:" block, attachments by basename.
- `import_service.dart` — `NoteImportService.import(List<ParsedNote>)` resolves
  label/notebook **names** → ids (find-or-create, deduped per run) and writes
  via `repo.importNote(NoteImport)`. The backend sets its own `created`, so the
  source's original date is appended to the body as a footnote (per design).
- `import_models.dart` — `ParsedNote` (label/notebook as names) + `ImportResult`.

### Account settings (`features/auth/account_settings_screen.dart`)
- "Test connection" button by the Server URL field pings `<typed-url>/api/health`
  (`pb.health.check()` on a throwaway client) and shows a status icon.
- Password change is **gated on reachability**: the button is disabled (with an
  inline "server not responding" notice) unless the active server is reachable.
  Probed on open and re-probed after saving a new URL.

## Build / run / test
```bash
# Backend + web UI (one container: app at /, API at /api, admin at /_/)
docker compose pull && docker compose up -d                  # deploy a release
docker compose -f docker-compose.build.yml up -d --build     # build from source
# → http://localhost:8090

# Flutter app dev
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift codegen (gitignored)
flutter run -d chrome        # web (login-gated)
flutter run -d <android>     # mobile (local-first)
flutter build apk --release  # APK -> build/app/outputs/flutter-apk/

# Remote sideload test build (no GitHub Actions): builds an arm64-v8a APK and
# uploads it as a GitHub Release asset (tag test-YYYYMMDD-HHMM). Needs `gh`.
# Repo is private -> on the phone, sign into github.com, open Releases, tap apk.
./scripts/release-apk.sh

# Tests (integration tests need the backend running at :8090)
flutter test
flutter analyze
```

### Gotchas
- **Web drift assets:** `app/web/sqlite3.wasm` + `drift_worker.js` are committed
  and required for the (mobile-shared) drift web config to compile; web doesn't
  actually open the DB. `AppDatabase` passes `web: DriftWebOptions(...)`.
- **Android release:** manifest declares `INTERNET` + `usesCleartextTraffic`
  (Flutter only auto-adds INTERNET for debug); release is debug-signed for now.
- **Docker build:** compiles Flutter inside a multi-stage image (pulls the ~2 GB
  Flutter SDK at build time only; final image ~120 MB). Needs a Docker disk
  ≥ ~16 GB. App SDK lower bound is `^3.12.0` so it builds on the cirruslabs
  `stable` image.
- **Testing widgets that own drift streams:** dispose the tree and
  `pump(Duration)` so drift's stream-cleanup timer fires before the
  "no pending timers" check.
- App ID: `com.noteesek.app`. State mgmt: Riverpod 3 (`StateProvider` is legacy;
  use `Notifier`).

## Roadmap
Planned features + the decisions behind them live in [docs/roadmap.md](docs/roadmap.md)
(undo, per-label colors, app lock, JSON backup, markdown, quick capture,
onboarding, sign-out-everywhere).

## Deferred / ideas
Release-signed APK, iOS, FTS5 search, reminders, HTTPS (then tighten cleartext).
CI publishes multi-arch images to `ghcr.io/hromad-a/noteesek` on version tags.
