/// <reference path="../pb_data/types.d.ts" />

// Shared notebooks (phase 1) — widen access on notes (and their children,
// checklist_items + attachments) so that any *member* of a note's notebook can
// read and write it, not just the note's owner.
//
// A caller is a member of a note's notebook when, for that note:
//   owner = me                         (the note's own owner — personal notes)
//   || notebook.owner = me             (they own the containing notebook)
//   || notebook.sharedWith ?= me       (the notebook is shared with them)
//
// Notes with no notebook (or a private, unshared one) keep today's pure
// owner-scoping — nothing changes for personal notes.
//
// `notes.createRule` is intentionally left as the relaxed "@request.auth.id !=
// ''" (migration 1700000011): owner.pb.js stamps owner = creator on create, and
// a member may create a note in a shared notebook. checklist_items/attachments
// createRule DOES move to the membership predicate so members can add items /
// images to a shared note they don't own.

const NOTE_MEMBER =
  "owner = @request.auth.id" +
  " || notebook.owner = @request.auth.id" +
  " || notebook.sharedWith.id ?= @request.auth.id";

// For children, traverse through the parent note's notebook.
const CHILD_MEMBER =
  "note.owner = @request.auth.id" +
  " || note.notebook.owner = @request.auth.id" +
  " || note.notebook.sharedWith.id ?= @request.auth.id";

migrate((app) => {
  const notes = app.findCollectionByNameOrId("notes");
  notes.listRule = NOTE_MEMBER;
  notes.viewRule = NOTE_MEMBER;
  notes.updateRule = NOTE_MEMBER;
  notes.deleteRule = NOTE_MEMBER;
  app.save(notes);

  for (const name of ["checklist_items", "attachments"]) {
    const c = app.findCollectionByNameOrId(name);
    c.listRule = CHILD_MEMBER;
    c.viewRule = CHILD_MEMBER;
    c.createRule = CHILD_MEMBER;
    c.updateRule = CHILD_MEMBER;
    c.deleteRule = CHILD_MEMBER;
    app.save(c);
  }
}, (app) => {
  const notes = app.findCollectionByNameOrId("notes");
  notes.listRule = "owner = @request.auth.id";
  notes.viewRule = "owner = @request.auth.id";
  notes.updateRule = "owner = @request.auth.id";
  notes.deleteRule = "owner = @request.auth.id";
  app.save(notes);

  for (const name of ["checklist_items", "attachments"]) {
    const c = app.findCollectionByNameOrId(name);
    c.listRule = "note.owner = @request.auth.id";
    c.viewRule = "note.owner = @request.auth.id";
    c.createRule = "note.owner = @request.auth.id";
    c.updateRule = "note.owner = @request.auth.id";
    c.deleteRule = "note.owner = @request.auth.id";
    app.save(c);
  }
});
