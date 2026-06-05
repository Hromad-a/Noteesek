# Noteesek app (Flutter)

Offline-first Keep-style client. Android-first; the `web` platform is enabled
only for fast UI iteration during development.

- Application ID: `com.noteesek.app`
- Local storage: SQLite via `drift`
- Backend: PocketBase (server URL is configurable on the login screen)

## Setup

```bash
flutter pub get
# Generate drift code (database.g.dart etc.) — required; it is gitignored.
dart run build_runner build --delete-conflicting-outputs
```

After changing any `drift` table or other generated source, re-run the
`build_runner` command (or use `dart run build_runner watch`).

### Web assets (required for the web build)

The web build runs SQLite via WebAssembly, so two assets must exist in `web/`
(committed in this repo, must match the dependency versions):

- `web/sqlite3.wasm` — from the `sqlite3` package's GitHub releases
- `web/drift_worker.js` — from the `drift` package's GitHub releases

`AppDatabase` passes these via `driftDatabase(web: ...)`. Without them, the app
throws *"When compiling to the web, the `web` parameter needs to be set"* the
first time it opens the database (i.e. right after login). Native/Android builds
don't use these.

## Run

```bash
flutter run -d chrome      # fast UI iteration
flutter run -d <android>   # on an emulator or device
```

## Build APK

```bash
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

## Structure

```
lib/
├── config/      # app config (server URL, etc.)
├── data/
│   ├── local/   # drift database (offline mirror)
│   ├── remote/  # PocketBase client
│   └── models/  # shared models
├── features/
│   ├── auth/    # login / register
│   └── notes/   # notes grid + editor
└── sync/        # last-write-wins sync engine (see docs/sync-protocol.md)
```
