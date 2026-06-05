# Noteesek

A self-hosted, Google Keep–style notes app. One Flutter codebase, two clients,
backed by a self-hosted [PocketBase](https://pocketbase.io) server. Multi-user.

- **Android** — **local-first**: works fully offline with no account; an
  optional server connection enables last-write-wins sync.
- **Web** — **online**: login-gated, reads/writes notes directly on the server
  with live realtime updates. Served by the server itself.

See [CLAUDE.md](CLAUDE.md) for the current architecture and [PLAN.md](PLAN.md)
for the original design narrative.

## Layout

```
Noteesek/
├── CLAUDE.md          # current architecture (source of truth)
├── PLAN.md            # original design & decisions
├── server/            # PocketBase backend (Docker; also serves the web app)
├── app/               # Flutter client (Android local-first + web online)
└── docs/              # sync protocol & notes
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

The same tag also triggers
[`.github/workflows/release-apk.yml`](.github/workflows/release-apk.yml), which
builds the Android APK and attaches it to the tag's GitHub Release as
`noteesek-<version>.apk` — downloadable from the repo's **Releases** page. The
APK is currently signed with the debug key (installable directly, not
Play-Store-ready); add a release keystore + `signingConfig` for store builds.

## Status

Feature-complete and verified against a live backend (APK + web image build):

- [x] Multi-user auth
- [x] Android local-first; optional server with last-write-wins sync
- [x] Web online client (login-gated, realtime, served by the server)
- [x] Text + checklist notes
- [x] Pin / archive / trash (restore · delete-forever · empty)
- [x] Image attachments (server-side **protected** files)
- [x] Note search (title / body / checklist text)

Next: FTS5 search, labels/colors, reminders, release-signed APK, HTTPS.
