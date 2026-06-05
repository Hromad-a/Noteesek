# Noteesek

A self-hosted, Google Keep–style notes app. Offline-first native Android client
that syncs to a self-hosted [PocketBase](https://pocketbase.io) backend.
Multi-user.

See [PLAN.md](PLAN.md) for the full design and decisions.

## Layout

```
Noteesek/
├── PLAN.md            # design & decisions
├── server/            # PocketBase backend (Docker Compose)
├── app/               # Flutter client (Android-first, web later)
└── docs/              # protocol & self-hosting notes
```

## Deploy (any machine with Docker)

Run a published release without checking out the source or building anything.
Grab the root [`docker-compose.yml`](docker-compose.yml) and run:

```bash
docker compose up -d
```

This pulls a prebuilt multi-arch image (amd64 + arm64) from the GitHub Container
Registry — `ghcr.io/hromad-a/noteesek` — with the web app, server, and schema
all bundled in. Then open:

- Web app: <http://localhost:8090/>
- Admin UI: <http://localhost:8090/_/>

Persistent data is stored in `./pb_data` next to the compose file (back it up by
copying that folder). To pin a version or change the port, copy `.env.example`
to `.env` and edit it.

## Quick start (backend, build from source)

```bash
cd server
docker compose up -d --build
```

PocketBase admin UI: <http://localhost:8090/_/>

## Releasing

Images are published automatically by
[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml)
when a semver tag is pushed:

```bash
git tag v0.2.0
git push origin v0.2.0
```

That builds and pushes `ghcr.io/hromad-a/noteesek` tagged `0.2.0`, `0.2`, `0`,
and `latest`. Use full `vX.Y.Z` tags so the version tags are derived correctly.

## Status

v1 feature-complete (verified against a live backend; APK builds):

- [x] Multi-user auth
- [x] Offline-first sync (last-write-wins per note)
- [x] Text + checklist notes
- [x] Pin / archive
- [x] Image attachments
- [x] Note search (title / body / checklist text)

Next: protect attachment files server-side, FTS5 search, labels/colors,
reminders, release-signed APK, Flutter web polish.
