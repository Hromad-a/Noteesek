/// <reference path="../pb_data/types.d.ts" />

// Shared notebooks (phase 1) — add `sharedWith` to notebooks: the set of users
// the owner has shared the notebook with. A user is a *member* of a notebook iff
// they're its `owner` OR they appear in `sharedWith`. Members can read the
// notebook and read/write the notes inside it (see the access-rule migration);
// only the owner may change `sharedWith` (update stays owner-only).
//
// Read rules (list/view) are widened here so members can see the notebook
// itself. Update/delete stay owner-only, so editing `sharedWith`, renaming and
// deleting remain the owner's privilege.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const collection = app.findCollectionByNameOrId("notebooks");

  collection.fields.add(new RelationField({
    name: "sharedWith",
    collectionId: users.id,
    maxSelect: 999,
    cascadeDelete: false,
  }));

  collection.listRule =
    "owner = @request.auth.id || sharedWith.id ?= @request.auth.id";
  collection.viewRule =
    "owner = @request.auth.id || sharedWith.id ?= @request.auth.id";

  app.save(collection);
}, (app) => {
  const collection = app.findCollectionByNameOrId("notebooks");
  if (collection.fields.getByName("sharedWith")) {
    collection.fields.removeByName("sharedWith");
  }
  collection.listRule = "owner = @request.auth.id";
  collection.viewRule = "owner = @request.auth.id";
  app.save(collection);
});
