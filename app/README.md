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
