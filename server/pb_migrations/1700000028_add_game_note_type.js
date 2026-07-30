/// <reference path="../pb_data/types.d.ts" />

// Add a third note type, "game" — a score counter for playing games. Its whole
// state (players + per-round scores) lives in the note's `body` as JSON, so no
// new collection is needed; it rides the existing note sync/backup/snapshots.
// The `notes.type` field is a `select`, so its allowed values must be widened
// here or the server would reject a game note on push/create.
migrate((app) => {
  const notes = app.findCollectionByNameOrId("notes");
  const type = notes.fields.getByName("type");
  type.values = ["text", "checklist", "game"];
  app.save(notes);
}, (app) => {
  const notes = app.findCollectionByNameOrId("notes");
  const type = notes.fields.getByName("type");
  type.values = ["text", "checklist"];
  app.save(notes);
});
