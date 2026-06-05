# Noteesek — Plan

A self-hosted, Google Keep–style notes app. Offline-first native Android app
that syncs to a self-hosted backend. Multi-user.

## Priorities

- **Android-first.** v1 targets a signed Android APK. The web client comes
  nearly for free later (Flutter web build) but is **not** a v1 goal.
- **Offline-first.** The app is fully usable with no network; changes sync when
  a connection is available.
- **Easy self-hosting.** Backend should be a single binary + a data folder to
  back up.

## Stack

- **Client:** Flutter (single codebase → signed Android APK now; web build later)
- **Backend:** PocketBase (single self-hosted Go binary: multi-user auth,
  SQLite, file storage, REST API)
- **On-device storage:** SQLite via `drift` (offline-first)
- **Search:** local offline search over title/body/checklist text (v1 uses a
  case-insensitive substring query; FTS5 is a future optimization)
- **Sync:** hand-rolled **last-write-wins per note**
- **Deployment:** backend runs via **Docker Compose** (single PocketBase service)

### Why this stack

- **PocketBase** removes ~80% of backend work (auth, DB, file storage, REST out
  of the box) and is about as easy to self-host as it gets — one binary + one
  data directory.
- **Flutter** produces a genuine signed APK and a web build from one codebase,
  with mature offline storage (`drift`).
- The main custom code we own is the **sync layer**.

> Note: PocketBase does **not** provide offline sync. We build that ourselves in
> the Flutter app. Turnkey sync engines (PowerSync, ElectricSQL) exist but add
> significant weight; for v1 we hand-roll the simple version.

## Architecture

```
┌─────────────┐         ┌─────────────┐
│ Flutter app │  REST   │ PocketBase  │
│ (Android)   │◄───────►│ (1 binary)  │
│ local SQLite│  sync   │  SQLite +   │
│  (drift)    │         │  file store │
└─────────────┘         └─────────────┘
  offline-first           source of truth
```

## Storage decision

**The database (PocketBase / SQLite) is the source of truth.** Notes are *not*
stored as markdown files on disk.

A "markdown files + SQLite index" model was considered (live `.md` files,
editable with external tools like Obsidian/git, zero lock-in) but rejected: it
would mean dropping PocketBase and rolling our own file↔index↔sync backend, and
external/round-trip editing isn't a goal. Keeping the DB as source of truth is
the lightest option with the least code.

Markdown remains available later only as an optional **on-demand export**
(v2+), not as the storage format.

## Data model

- **note**: `id`, `owner`, `type` (`text` | `checklist`), `title`, `body`,
  `pinned`, `archived`, `deleted` (soft-delete), `created_at`, `updated_at`
- **checklist_item**: `id`, `note_id`, `text`, `checked`, `position`
- **attachment**: `id`, `note_id`, `file`, `mime`, `created_at`

(v2: labels, colors, reminders, sharing.)

## Sync protocol (last-write-wins per note)

1. Each record carries a server `updated_at` plus a local dirty flag.
2. **Push:** send locally-changed records; server keeps whichever `updated_at`
   is newest.
3. **Pull:** request records changed since `last_synced_at`; apply newest-wins
   locally.
4. **Deletes are soft** (`deleted=true`) so they propagate; hard-purge later.
5. **Attachments** upload on push; download lazily on pull.

Last-write-wins is per-note and adequate for personal use across one user's own
devices, where concurrent edits to the same note are rare.

## v1 scope

- [x] Multi-user auth (PocketBase)
- [x] Offline-first with background sync
- [x] Note types: **text** + **checklist**
- [x] **Pin** + **archive**
- [x] **Images / attachments**
- [x] **Full-text search** (offline, FTS5)

## Repository structure

Single repo (monorepo). The Flutter app and PocketBase backend share a data
model and sync contract, so a schema change and its client change land in one
atomic commit. With a single primary developer and a small backend, there's no
reason to split. Going mono→multi later is easy (`git subtree split`); the
reverse is painful — so monorepo is the low-regret default.

```
Noteesek/
├── PLAN.md
├── README.md
├── server/                 # PocketBase
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── pb_migrations/      # collection schema as code (version-controlled)
│   └── pb_hooks/           # optional custom JS hooks
├── app/                    # Flutter (Android now, web later)
│   ├── lib/
│   ├── android/
│   └── pubspec.yaml
└── docs/                   # sync protocol, self-hosting guide, etc.
```

- **`pb_migrations/` is committed** — it defines collections as code, so the
  schema is reproducible and reviewable.
- **`pb_data/` is gitignored** — it's PocketBase runtime data/backups, not
  source.

### Deployment (Docker Compose)

The **backend** runs via Docker Compose as a single PocketBase service. The
**Flutter app is not a container** — it compiles to an APK that runs on the
phone and talks to PocketBase over the network. (`docker compose up` brings up
the backend; the phone connects to it.)

- `server/Dockerfile` downloads the PocketBase binary onto a small Alpine image.
- `server/docker-compose.yml` runs one `pocketbase` service with bind-mounted
  volumes:
  - `pb_data/` → persistent data (gitignored; backup = copy this folder)
  - `pb_migrations/` → schema as code, auto-applied on startup (committed)
  - `pb_hooks/` → optional custom JS hooks (committed)
- Stays lightweight: one service, ~10–30 MB idle RAM.
- HTTPS via a reverse proxy (Caddy/Traefik) is a later deployment detail, not
  part of the v1 compose file.

## Build order

1. PocketBase: collections (`note`, `checklist_item`, `attachment`) + auth
   rules + `docker-compose` for self-hosting.
2. Flutter scaffold: auth screen → Keep-style notes grid.
3. Local SQLite (`drift`) schema + repository layer.
4. Note editor (text + checklist), pin/archive, image attach.
5. FTS5 search.
6. Sync engine (push/pull/LWW) + conflict handling.
7. APK build + self-host docs.

## Deferred (v2+)

- Colors + labels/tags
- Reminders / notifications
- Note sharing between users
- Web client (Flutter web)
- iOS build
- Markdown export
