# Noteesek

A self-hosted, Google Keep–style notes app you run on your own server. Your
notes live entirely on **your** server — no third-party cloud.

> ⚠️ **Heads up — this is a "vibecoded" project.** It was built largely through
> AI-assisted, exploratory coding rather than rigorous engineering. It works for
> my own use, but expect rough edges and bugs. **No guarantees** — use it at your
> own risk and keep backups of your data. Issues/PRs welcome; support is
> best-effort.

One Flutter codebase gives you two clients, backed by a single
[PocketBase](https://pocketbase.io) server (one small Docker container):

- **📱 Android** — *local-first.* Works fully offline with no account. Connect
  your server to sync across devices (last-write-wins).
- **🌐 Web** — *online.* Login-gated, live realtime updates, served by the server
  itself. Just open your server's URL in a browser.

## Features

- Text & checklist notes — pin, archive, trash (restore / delete-forever)
- Note **colors** and **image backgrounds** (upload your own, set opacity /
  overlay / fit)
- **Labels** (with colors) and **notebooks** to organize
- **Shared notebooks** — share a notebook with other users; everyone edits its
  notes together, live
- Image attachments, search, and filters (notebook / label / color / type / image)
- Markdown rendering + a formatting toolbar
- **Version history** — scheduled, server-side snapshots you can restore from
- Full backup & restore, plus Markdown / plain-text / PDF export and import
  (Markdown, Google Keep Takeout)
- Light / dark / system theme · **English & Czech**
- App lock (PIN + biometrics), quick capture (Android share-to-Noteesek)

## Get started

### 1. Run the server (Docker)

Everything — the web app, the server, and the database schema — ships in one
container. The only state to back up is the `./pb_data` folder next to the
compose file.

```bash
docker compose pull && docker compose up -d
```

Then open:

- **Web app:** <http://localhost:8090/>
- **Admin UI:** <http://localhost:8090/_/>

To pin a version, change the port, bootstrap an admin, or configure password-
reset email, copy [`.env.example`](.env.example) to `.env` and edit it (all
optional). To build the image from source instead of pulling it:

```bash
docker compose -f docker-compose.build.yml up -d --build
```

### 2. Use it

- **On the web:** open your server's URL and register / sign in.
- **On Android:** grab the latest `noteesek-<version>.apk` from the repo's
  [**Releases**](../../releases) page and install it. The app works offline right
  away; open **Settings → Account** to connect it to your server and sync.

## Your data

Your notes never leave your server. Back up by copying the `pb_data/` folder, or
use the in-app **Settings → Data & storage → Back up to file** (a full,
restorable backup). Version history adds automatic, scheduled snapshots on the
server.

## Development

The app is Flutter (Android + web) and the backend is PocketBase. Architecture
and conventions live in [CLAUDE.md](CLAUDE.md); the original design narrative is
in [PLAN.md](PLAN.md).

```bash
cd app
flutter pub get
flutter run -d chrome     # web
flutter run -d <android>  # mobile
```

Pushing a `vX.Y.Z` tag publishes the Docker image and attaches a built APK to the
GitHub Release automatically.
