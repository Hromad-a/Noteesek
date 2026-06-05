# Noteesek app (Flutter)

One codebase, two clients (see the repo root [CLAUDE.md](../CLAUDE.md)):

- **Android — local-first.** Offline SQLite (`drift`) store; works with no
  account. An optional server connection enables last-write-wins sync.
- **Web — online.** Login-gated; reads/writes go directly to PocketBase with
  realtime updates. No local DB or sync engine. Served by the server.

The platform is branched with `kIsWeb`; both share a `NotesRepository` interface
(`LocalNotesRepository` for mobile, `RemoteNotesRepository` for web).

- Application ID: `com.noteesek.app`
- Backend: PocketBase (server URL configurable; web defaults to its own origin)

## Setup

```bash
flutter pub get
# Generate drift code (database.g.dart etc.) — required; it is gitignored.
dart run build_runner build --delete-conflicting-outputs
```

Re-run `build_runner` after changing any `drift` table or other generated
source (or use `dart run build_runner watch`).

### Web build assets

`app/web/sqlite3.wasm` and `app/web/drift_worker.js` are committed and must match
the `sqlite3` / `drift` dependency versions. They satisfy the shared
`driftDatabase(web: ...)` config so the app compiles for web — the web client
does **not** actually open a local database at runtime (it uses the remote
repository), but the shared code must still compile.

## Run

```bash
flutter run -d chrome      # web (online, login-gated). Point the server URL at
                           # your PocketBase, e.g. http://localhost:8090
flutter run -d <android>   # mobile (local-first)
```

## Build APK

```bash
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

The main `AndroidManifest.xml` declares `INTERNET` + `usesCleartextTraffic` so
release builds can reach a self-hosted (often HTTP/LAN) server. The release is
currently debug-signed.

## Structure

```
lib/
├── app.dart                 # web = login-gated, mobile = local-first
├── main.dart
├── providers.dart           # prefs, db, pocketbase, auth, active owner
├── config/app_config.dart
├── data/
│   ├── notes_repository.dart        # abstract interface + Riverpod providers
│   ├── local_notes_repository.dart  # drift impl (mobile)
│   ├── remote_notes_repository.dart # PocketBase + realtime impl (web)
│   └── local/                       # drift database + id/time helpers
├── features/
│   ├── auth/                # login / connect screen
│   └── notes/               # grid, editor, note card, archive, trash
└── sync/                    # last-write-wins engine + controller (MOBILE ONLY)
```

## Tests

```bash
flutter test       # integration tests (sync_*, remote_*) need the backend at :8090
flutter analyze
```
