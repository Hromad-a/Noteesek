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

## Quick start (backend)

```bash
cd server
docker compose up -d
```

PocketBase admin UI: <http://localhost:8090/_/>

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
