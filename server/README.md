# Noteesek server (PocketBase)

Single-binary PocketBase backend, run via Docker Compose. Pinned to PocketBase
**v0.39.1** (uses the v0.23+ `fields`-based collection/migration API).

## Run

```bash
docker compose up -d --build
```

The image is **multi-stage**: it builds the Flutter web app and serves it from
PocketBase's `pb_public`, so one container provides the app, API, and admin:

- Web app: <http://localhost:8090/>
- REST API: <http://localhost:8090/api/>
- Admin dashboard: <http://localhost:8090/_/>

The web app defaults its server URL to its own origin, so it works out of the
box. Migrations in `pb_migrations/` are applied automatically on startup.

> The build compiles Flutter inside Docker (pulls the ~2 GB Flutter SDK image at
> build time only — it is **not** in the final image). The final image is ~120 MB
> (Alpine + PocketBase + the compiled web bundle). The build needs a Docker disk
> of ~16 GB+ for the SDK image; bump Docker Desktop → Settings → Resources if a
> build fails with "no space left on device".

## First superuser

Create an admin without the browser flow:

```bash
docker compose exec pocketbase /pb/pocketbase superuser upsert you@example.com 'a-strong-password'
```

## Collections

| Collection        | Purpose                                   |
|-------------------|-------------------------------------------|
| `users`           | auth (built-in)                           |
| `notes`           | text/checklist note + pin/archive/deleted |
| `checklist_items` | rows of a checklist note                  |
| `attachments`     | images/files attached to a note           |

All app collections are **owner-scoped**: every rule resolves to
`owner = @request.auth.id` (directly on `notes`, or via `note.owner` on the
child collections). A user can only ever read or write their own data.

Each record carries `created` + `updated` autodate fields; `updated` is the
cursor the client uses for last-write-wins sync. Deletes are **soft**
(`deleted = true`) so they propagate before being purged.

## Data & backup

- All runtime state lives in `pb_data/` (gitignored). **Back up by copying that
  folder.**
- Schema lives in `pb_migrations/` (committed) and is reproducible from an empty
  `pb_data/`.

## Notes for development

If you apply new migrations against an already-running container, restart it so
PocketBase reloads its in-memory collection cache:

```bash
docker compose restart
```
