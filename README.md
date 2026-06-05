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

Early development. v1 scope:

- Multi-user auth
- Offline-first sync (last-write-wins per note)
- Text + checklist notes
- Pin / archive
- Image attachments
- Full-text search
