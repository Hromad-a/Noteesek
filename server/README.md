# Noteesek server (PocketBase)

Single-binary PocketBase backend, run via Docker Compose. Pinned to PocketBase
**v0.39.1** (uses the v0.23+ `fields`-based collection/migration API).

## Run

```bash
docker compose up -d --build
```

- REST API: <http://localhost:8090/api/>
- Admin dashboard: <http://localhost:8090/_/>

Migrations in `pb_migrations/` are applied automatically on startup.

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
