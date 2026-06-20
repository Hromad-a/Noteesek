# Backup, export & version history — UX design

**Status:** proposed (design agreed; not yet implemented). Pairs with the format
spec in `backup-format-v2.md`. Captured 2026-06-20.

## The problem

Three features all sound like "backup" and overlap in users' heads:

1. **Markdown export/import** — readable files to move notes to another app or
   into a different notebook.
2. **Version history** — periodic point-in-time snapshots on the server; restore
   the whole account or selected notes.
3. **Backup file** — a single lossless file you keep locally and restore later.

Goal: make it obvious **what each does** and **visually separate** them, and
settle how restore/preview/selection works.

## Two formats, three jobs

There are really only **two formats**, and version history is just one of them
produced automatically:

| Format | What it is | Fidelity | On import |
|--------|-----------|----------|-----------|
| **Markdown** (`.zip` of `.md` + `attachments/`) | readable interchange for *other* apps | partial — text/checklists/images/labels/notebook/color/dates kept; ids + sync state dropped; Trash excluded | **new copies** (new ids) |
| **Backup (v2 `.zip`)** | exact Noteesek archive (see `backup-format-v2.md`) | lossless — everything incl. ids + Trash | exact **restore** (by id) |

**Version history = the v2 archive format, produced automatically and stored on
the server as a repository.** So a **downloaded snapshot is byte-identical to a
saved backup file**, and both restore through the same screen. The server keeps
its internal deduped blob store for efficiency, but the user-facing artifact and
flow are the same.

## Plain language — drop "lossy/lossless"

"Lossy" is jargon and sounds like damage. Describe the thing users care about —
*copies vs exact restore*:

- Markdown → **"Readable files for other apps · re-importing adds new copies"**
- Backup file → **"An exact copy you can restore later"**

## Settings layout — grouped by direction

Users arrive thinking "I want to export" / "I want to import", so group by verb:

```
Backup & export
  Export
    • Markdown          — Readable files for other apps · re-importing adds copies
    • Backup file (.zip) — An exact copy you can restore later
  Import
    • Notes (Markdown / Keep) — Adds copies into a notebook
    • Backup file            — Restore all, or merge selected
  Server  (signed in only)
    • Version history — Automatic restore points
    • Sync            — status
```

The two **Import** rows go to *different* destinations:
- *Notes (Markdown / Keep)* → a simple copy-in (always new ids; pick a target
  notebook). No "replace".
- *Backup file* → the shared **preview** screen (below), with Add **and** Replace.

## The shared preview / restore screen

**One screen, reused everywhere a package is opened** — restoring a backup file,
viewing/restoring a server snapshot, and the Markdown import selection. Learn it
once.

Layout:
- **Header:** source + timestamp, counts (N notes · M images · size), and a
  **health badge** — `verified` or `N damaged` (the fault-isolation payoff from
  v2; damaged entries are skipped, never block the rest).
- **Search box** — filter notes by title (matters for big backups).
- **Notebook-grouped, collapsible list** with **tri-state checkboxes**:
  - Each notebook row's checkbox = the whole notebook (checked / dash = partial /
    empty). So "import these 3 notebooks" is three taps on the headers.
  - Expand a notebook to refine individual notes (with thumbnails).
  - A **"No notebook"** group catches uncategorised notes.
  - **Labels are a *filter*, not a grouping** (a note can have several labels, so
    they don't partition cleanly) — optional label-filter chips.
- **Selection summary** (`2 notebooks · 21 notes`) + All / None.
- **Footer:** the two restore modes (below).

This grouped list *is* the notebook→note tree; a literal node/edge tree-graph is
overkill for two levels and busier than a familiar file-picker grouping.

## Restore modes (one vocabulary everywhere)

| Mode | Uses | Ids | Effect | Guard |
|------|------|-----|--------|-------|
| **Add to my notes** | the **selection** (default = all) | **new** (copies) | brings notes in alongside what you have; stamps current account; resolves labels/notebooks **by name**; optional target notebook | none (non-destructive) |
| **Replace everything** | the **whole** file (selection ignored) | preserved | account becomes exactly the backup; notes not in it → Trash | type-to-confirm |

"Whole vs selected" is **not a separate mode** — it's just selection state:
Add-with-all = "import the whole thing", Add-with-some = a subset. Replace is
always whole (replacing with a subset isn't meaningful).

Use the **same Add/Replace words** across backup-file restore, snapshot restore,
and (for the destructive case) sign-in reconciliation, so the vocabulary is
consistent.

## Implementation mapping

- **Replace/restore** = `BackupService.importV2()` / `RemoteBackupService.importV2()`
  — upsert by id, preserve ids. **Already built** (phase 2).
- **Add (copies)** = a new `importV2Copy(..., {selectedNoteIds, targetNotebook})`
  — mint new ids, stamp current owner, resolve labels/notebooks by name, remap
  relations. **Not built yet** — reuses the collision-safe logic already in the
  Markdown importer (`NoteImportService`) and sign-in reconciliation re-id.
- **Selective** = filter which `notes/<id>.json` (and their attachments) are
  applied; the manifest index + notebook grouping drive the picker without
  reading note bodies.
- **Snapshot ↔ file unity** = a server route to **download a snapshot as a v2
  zip** (assemble from the snapshot JSON + blobs) so snapshots and backup files
  share the format, the preview, and the restore code.
- Follow-up from `backup-format-v2.md`: move `snapshot_blobs` from id- to
  **content-hash** dedup.

## Anti-confusion principles (summary)

1. Group by **verb** (Export / Import / Server), not by mechanism.
2. Put **fidelity in the sub-label** (copies vs exact restore), never jargon.
3. **One shared preview** for every package (file, snapshot, import).
4. **One Add/Replace vocabulary** everywhere.
5. Snapshots and backup files are the **same format** — say so in the UI ("same
   format as a server snapshot").

## Phasing

- **3a — shared preview widget**: manifest-driven, notebook-grouped, tri-state
  selection, search, thumbnails, health/verify. Adds the `image` dep + a
  thumbnailer (the v2 writer already accepts one).
- **3b — Add-copies import mode** (`importV2Copy`) on both platforms.
- **3c — settings reorg** into Export / Import / Server.
- **3d — snapshot download-as-v2** + reuse the preview for snapshot restore;
  `snapshot_blobs` → content-hash.
- **3e — Markdown import** adopts the same selection + target-notebook flow.
