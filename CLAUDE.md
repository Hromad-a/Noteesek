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
├── server/            # PocketBase backend (Docker)
│   ├── Dockerfile         # multi-stage: builds Flutter web -> serves from pb_public
│   ├── docker-compose.yml # build context = repo root (..)
│   └── pb_migrations/     # collections + schema as code (committed)
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

Protected files require a short-lived token (`pb.files.getToken()`) to download.
`created`/`updated` are autodate; `updated` drives last-write-wins sync. Labels
sync first each cycle so a note's `labels` relation resolves server-side.

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
`ManageLabelsScreen`) · **account settings** (change password / server URL /
sign out) · empty notes auto-move to Trash on close.

## Build / run / test
```bash
# Backend + web UI (one container: app at /, API at /api, admin at /_/)
cd server && docker compose up -d --build        # http://localhost:8090

# Flutter app dev
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift codegen (gitignored)
flutter run -d chrome        # web (login-gated)
flutter run -d <android>     # mobile (local-first)
flutter build apk --release  # APK -> build/app/outputs/flutter-apk/

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

## Deferred / ideas
Release-signed APK, iOS, FTS5 search, reminders, per-label colors, HTTPS (then
tighten cleartext). CI publishes multi-arch images to `ghcr.io/hromad-a/noteesek`
on version tags.
