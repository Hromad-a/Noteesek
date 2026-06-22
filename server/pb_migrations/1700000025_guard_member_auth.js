/// <reference path="../pb_data/types.d.ts" />

// Security fix: the shared-notebook access predicates (migration 1700000019)
// can match an UNAUTHENTICATED request. For empty auth, `@request.auth.id` is
// "", so `notebook.owner = @request.auth.id` matches notes with no notebook
// (empty = empty), and the relation `?=` checks behave loosely — leaking
// no-notebook notes (and notebooks) to anyone. Prefix every member predicate
// with an explicit `@request.auth.id != ""` guard so only signed-in users match.

const NOTE_MEMBER =
  '@request.auth.id != "" && (' +
  "owner = @request.auth.id" +
  " || notebook.owner = @request.auth.id" +
  " || notebook.sharedWith.id ?= @request.auth.id)";

const CHILD_MEMBER =
  '@request.auth.id != "" && (' +
  "note.owner = @request.auth.id" +
  " || note.notebook.owner = @request.auth.id" +
  " || note.notebook.sharedWith.id ?= @request.auth.id)";

const NOTEBOOK_MEMBER =
  '@request.auth.id != "" && (' +
  "owner = @request.auth.id || sharedWith.id ?= @request.auth.id)";

function setRules(collection, rules) {
  for (const k of Object.keys(rules)) collection[k] = rules[k];
}

migrate((app) => {
  const notes = app.findCollectionByNameOrId("notes");
  setRules(notes, {
    listRule: NOTE_MEMBER,
    viewRule: NOTE_MEMBER,
    updateRule: NOTE_MEMBER,
    deleteRule: NOTE_MEMBER,
  });
  app.save(notes);

  for (const name of ["checklist_items", "attachments"]) {
    const c = app.findCollectionByNameOrId(name);
    setRules(c, {
      listRule: CHILD_MEMBER,
      viewRule: CHILD_MEMBER,
      createRule: CHILD_MEMBER,
      updateRule: CHILD_MEMBER,
      deleteRule: CHILD_MEMBER,
    });
    app.save(c);
  }

  const notebooks = app.findCollectionByNameOrId("notebooks");
  setRules(notebooks, {
    listRule: NOTEBOOK_MEMBER,
    viewRule: NOTEBOOK_MEMBER,
  });
  app.save(notebooks);
}, (app) => {
  // Revert to the unguarded predicates (migration 1700000019 / 1700000018).
  const NOTE = "owner = @request.auth.id || notebook.owner = @request.auth.id" +
    " || notebook.sharedWith.id ?= @request.auth.id";
  const CHILD = "note.owner = @request.auth.id" +
    " || note.notebook.owner = @request.auth.id" +
    " || note.notebook.sharedWith.id ?= @request.auth.id";
  const notes = app.findCollectionByNameOrId("notes");
  setRules(notes, { listRule: NOTE, viewRule: NOTE, updateRule: NOTE, deleteRule: NOTE });
  app.save(notes);
  for (const name of ["checklist_items", "attachments"]) {
    const c = app.findCollectionByNameOrId(name);
    setRules(c, { listRule: CHILD, viewRule: CHILD, createRule: CHILD, updateRule: CHILD, deleteRule: CHILD });
    app.save(c);
  }
  const notebooks = app.findCollectionByNameOrId("notebooks");
  const NB = "owner = @request.auth.id || sharedWith.id ?= @request.auth.id";
  setRules(notebooks, { listRule: NB, viewRule: NB });
  app.save(notebooks);
});
