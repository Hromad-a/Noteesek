# Backup format v2 — fault-isolated, previewable, selective (design)

**Status:** proposed (not implemented). Supersedes the v1 single-JSON backup for
new exports; v1 imports stay supported. Resilience tier: **L0 + L1** (per-file
isolation + checksums, plus a duplicated index) — no forward-error-correction.

## Why v2

v1 (`BackupService` / `RemoteBackupService`) writes **one JSON document** with
every image **base64-inlined**. Problems:

- **No fault isolation.** One corrupt byte anywhere makes `jsonDecode` throw →
  the *entire* backup (all notes + images) is lost, not just the damaged part.
- **Memory-heavy.** The whole file + every decoded image must be in memory at
  once → OOM risk with many/large images.
- **No preview / no partial restore.** You can't see what's inside or import a
  subset without parsing everything.
- base64 inflates image bytes ~33%.

v2 keeps the **lossless** content of v1 but stores it as **many small files in a
zip**, with an index for preview and per-file integrity.

## Goals / non-goals

**Goals:** corruption isolation (lose only the damaged note/image); integrity
verification; quick preview (titles + thumbnails) without a full import;
selective import of chosen notes; bounded memory (stream entries); back-compat
import of v1 files.

**Non-goals (this version):** forward error correction / self-healing (L2/L3);
encryption (can wrap later); cross-device sync semantics.

## Container & layout

A single **zip** (`archive` package already in use). The zip central directory
gives O(1) listing + random-access single-entry extraction (preview + selective
import) and a **CRC32 per entry** (free corruption detection).

```
noteesek-backup-YYYYMMDD-HHMM.zip
├── manifest.json        # index + integrity registry (read this alone to preview)
├── manifest.bak.json    # byte-identical copy of manifest.json  (L1)
├── notes/
│   └── <noteId>.json    # one self-contained record per note (note + its items +
│                        #   its attachment metadata)
├── attachments/
│   └── <attachmentId>.<ext>   # raw image bytes, one file per attachment, by id
└── thumbs/
    └── <attachmentId>.webp    # ~256px (long edge) thumbnail for fast preview
```

- Image files are **stored** (not deflated) in the zip — JPEG/PNG/WebP are
  already compressed; JSON entries are deflated.
- Attachments are keyed by **attachment id** and shared: a note references ids,
  so an image referenced by multiple notes is stored once.

## `manifest.json`

Small (kilobytes); the only thing you read to render a full preview. It is also
the **integrity registry** for every entry, which is why it is duplicated (L1).

```jsonc
{
  "format": 2,
  "app": "1.4.7+13",
  "exportedAt": "2026-06-20T08:00:00.000Z",
  "counts": { "notes": 42, "attachments": 8, "labels": 5, "notebooks": 3 },

  // Shared definitions (so a selectively-imported note's relations resolve).
  "labels":    [{ "id": "...", "name": "Travel", "color": "mint",
                  "deleted": false, "created": "...", "updated": "..." }],
  "notebooks": [{ "id": "...", "name": "Trips",
                  "deleted": false, "created": "...", "updated": "..." }],

  // Lightweight per-note index for preview + selection (NO bytes, NO full body).
  "notes": [{
    "id": "abc123",
    "file": "notes/abc123.json",
    "title": "Packing",
    "snippet": "socks, passport, charger…",   // first ~140 chars of body/items
    "type": "text",                            // text | checklist
    "color": "lavender",
    "pinned": false, "archived": false, "deleted": false,
    "labelIds": ["..."],
    "notebookId": "...",
    "created": "...", "updated": "...",
    "attachmentIds": ["img1"],
    "thumbs": ["thumbs/img1.webp"]             // for the preview grid
  }],

  // Integrity registry: SHA-256 of every NON-manifest entry in the zip.
  // Verifies content (stronger than zip CRC32) and catches tampering.
  "files": {
    "notes/abc123.json":      "sha256-…",
    "attachments/img1.jpg":   "sha256-…",
    "thumbs/img1.webp":       "sha256-…"
  }
}
```

`manifest.bak.json` is identical. On read: parse `manifest.json`; if it fails its
own structural check, fall back to `manifest.bak.json`.

## `notes/<noteId>.json`

Self-contained so a single note can be imported in isolation. Holds the note
record, its checklist items, and metadata for its attachments (bytes live in
`attachments/`).

```jsonc
{
  "id": "abc123",
  "type": "text",
  "title": "Packing",
  "body": "socks, passport…",        // markdown text (text notes)
  "color": "lavender",
  "pinned": false, "archived": false, "deleted": false,
  "position": 3,
  "created": "...", "updated": "...",
  "labelIds": ["..."],               // resolve via manifest.labels
  "notebookId": "...",               // resolve via manifest.notebooks ("" = none)
  "items": [                          // checklist notes only
    { "id": "...", "text": "passport", "checked": true, "position": 0,
      "deleted": false, "created": "...", "updated": "..." }
  ],
  "attachments": [
    { "id": "img1", "ext": "jpg", "mime": "image/jpeg", "bytes": 84213,
      "sha256": "sha256-…", "deleted": false,
      "created": "...", "updated": "..." }
  ]
}
```

Notes:
- **`owner` is intentionally omitted.** v2 backups are account-portable; import
  always stamps the importing account (see modes). (v1 stored `owner`; restoring
  a v1 file keeps its behaviour.)
- Trashed notes (`deleted: true`) are **included** by default (lossless), flagged
  so preview can hide them and selective import can exclude them.

## Integrity model

- **L0 — detection + isolation.** Every entry has a zip **CRC32** (checked on
  extract) and a **SHA-256** in `manifest.files`. A corrupt `notes/<id>.json`
  fails only that note; a corrupt `attachments/<id>` fails only that image. The
  rest verify and import normally.
- **L1 — index redundancy.** `manifest.json` is duplicated as `manifest.bak.json`
  so the index (needed for preview + selection) survives a single corruption.
- **No L2/L3.** No mirroring of note/image bodies and no parity/Reed-Solomon —
  by decision, to avoid fragile error-correction code. Durability beyond this is
  achieved operationally (keep ≥2 backups in ≥2 places; verify periodically).

## Export flow

Platform-split as today (mobile reads the drift DB; web reads the PocketBase
API), but both emit the **same v2 zip**:

1. Gather labels + notebooks → `manifest.labels` / `manifest.notebooks`.
2. For each note: write `notes/<id>.json` (note + items + attachment metadata);
   add a `manifest.notes` index entry (title, snippet, flags, thumb refs).
3. For each attachment with bytes: write `attachments/<id>.<ext>`; generate and
   write `thumbs/<id>.webp`; record `bytes` + `sha256`.
   - Mobile: bytes from the local DB. Web: download via the file token (as the
     current web backup does), streamed one at a time (bounded memory).
4. Compute `manifest.files` SHA-256 for each written entry.
5. Write `manifest.json` + `manifest.bak.json`.
6. Deliver via the existing `deliverBytes` / `save_delivery` paths.

Thumbnails: decode + downscale to ~256px long edge, WebP/JPEG q≈70. Skip (and
omit `thumbs`) if decode fails — preview falls back to a placeholder.

## Preview flow

Open the zip, read **only** `manifest.json` (fallback `.bak`). Render the note
list from the index (title, snippet, labels, dates, flags) and a thumbnail grid
by extracting just the referenced `thumbs/*` on demand. No note bodies or
full-res images are read until a note is opened/selected. Show a per-entry
"damaged" badge for any file whose CRC/SHA fails.

## Import flow

1. **Read + verify** the manifest (fallback to `.bak`). List entries; verify each
   selected entry's SHA-256 against `manifest.files`. Damaged entries are flagged
   and **skipped** (never abort the whole import).
2. **Select** (optional): user picks notes from the preview; default = all
   non-trashed. Resolves to the chosen `notes/<id>.json` + their `attachmentIds`
   + the shared labels/notebooks they reference.
3. **Mode:**
   - **Restore (lossless)** — same account or a fresh/empty server: upsert by id,
     preserve ids + timestamps (current `BackupService.import` behaviour). Best
     for "recover my account."
   - **Import (copy)** — *default for selective import*, and required when the id
     might already exist (e.g. importing into a *different* account on the same
     server): **mint new ids**, stamp the active account, and resolve
     labels/notebooks **by name** (find-or-create), remapping relations — the
     same collision-free path the Markdown importer + sign-in reconciliation use.
4. **Write** parents before children (labels/notebooks → notes → items →
   attachments), streaming attachment bytes from `attachments/<id>`.
5. **Report**: imported N notes / M attachments; list any skipped-because-damaged
   entries by name.

### Back-compat (v1)

The importer **auto-detects** the input:
- A bare `.json` whose root has `"format": 1` → existing v1 base64 path.
- A `.zip` whose `manifest.json` has `"format": 2` → v2 path.
- (Also still accept the Markdown export zip + loose `.md`, as today.)

So existing v1 backups keep restoring unchanged.

## Failure handling / edge cases

- **Both manifests corrupt:** fall back to a best-effort scan — enumerate
  `notes/*.json`, import those that parse + verify; attachments matched by id.
  Degraded but not total loss (the per-note files are still independent).
- **Attachment bytes missing/corrupt but note OK:** import the note without that
  image; flag it.
- **Thumb missing/corrupt:** cosmetic only; show a placeholder.
- **Duplicate ids on restore into a non-empty same-account server:** restore =
  upsert (backup wins); copy = new ids (no collision).
- **Large backups:** entries are processed one at a time; never hold the whole
  archive decoded in memory.

## Versioning & open decisions

- `format: 2` gates the new path; bump on incompatible layout changes.
- **Open:** thumbnail format (WebP vs JPEG — WebP smaller, ensure web decode);
  whether to include trashed notes by default (proposed: yes, flagged);
  default import mode for *full* (non-selective) import (proposed: Restore for
  same-account, Copy when foreign/duplicate ids detected).

## Suggested implementation phasing

1. **Writer + reader of the v2 zip** (pure, unit-tested: round-trip a set of
   notes/items/attachments; assert per-file isolation by corrupting one entry and
   confirming the rest still import). No UI yet; wire v2 as the export format
   behind the existing "Back up to file".
2. **Verify-on-import + v1 auto-detect back-compat.** Replace the import entry
   point; keep v1 restore working.
3. **Preview + selective import UI** (manifest-driven list + thumbnail grid +
   checkbox selection), shared by mobile + web.

The direction is already validated in this codebase: the **Markdown export**
uses a zip + `attachments/` folder, and the **server snapshots** store images as
separate files shared by id — v2 brings the same robustness to the lossless
backup, plus an index for preview and selective restore.
