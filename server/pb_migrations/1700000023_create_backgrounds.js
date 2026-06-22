/// <reference path="../pb_data/types.d.ts" />

// backgrounds — an owner-scoped *library* of image backgrounds a note can use
// (parallel to note colors, but user-uploaded images with display options).
// A note references one by id (notes.background). Each library entry carries its
// own display options (opacity, overlay, fit, repeat, scale) set once in the app
// Settings; the note just picks which image.
//
// Access: you only LIST your own (no enumerating other accounts), but any signed
// -in user may VIEW one by id — needed so a *member* of a shared notebook can
// fetch + render the background a shared note references (they learn the id from
// the note). The file is protected (short-lived token, like attachments).
// owner is stamped server-side by owner.pb.js (createRule stays relaxed).
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");

  const collection = new Collection({
    type: "base",
    name: "backgrounds",
    listRule: "owner = @request.auth.id",
    viewRule: "@request.auth.id != ''",
    createRule: "@request.auth.id != ''",
    updateRule: "owner = @request.auth.id",
    deleteRule: "owner = @request.auth.id",
    fields: [
      {
        type: "relation",
        name: "owner",
        required: true,
        maxSelect: 1,
        collectionId: users.id,
        cascadeDelete: true,
      },
      { type: "text", name: "name", max: 200 },
      {
        type: "file",
        name: "file",
        required: true,
        maxSelect: 1,
        maxSize: 26214400, // 25 MB
        protected: true,
      },
      // Display options (applied wherever this background is used).
      { type: "number", name: "opacity" }, // 0..1 (image fade)
      { type: "text", name: "overlayColor", max: 30 }, // hex, '' = none
      { type: "number", name: "overlayOpacity" }, // 0..1 (overlay strength)
      { type: "text", name: "fit", max: 20 }, // cover|contain|fill|none
      { type: "text", name: "repeat", max: 20 }, // none|repeat|repeatX|repeatY
      { type: "number", name: "scale" }, // image scale multiplier
      { type: "bool", name: "deleted" },
      { type: "autodate", name: "created", onCreate: true },
      { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
    ],
    indexes: [
      "CREATE INDEX idx_backgrounds_owner ON backgrounds (owner)",
    ],
  });

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("backgrounds");
  app.delete(collection);
});
