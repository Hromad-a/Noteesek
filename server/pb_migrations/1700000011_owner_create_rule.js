/// <reference path="../pb_data/types.d.ts" />

// Make `owner` server-authoritative on create (pairs with pb_hooks/owner.pb.js).
//
// PocketBase enforces the createRule BEFORE the onRecordCreateRequest hook runs,
// so a `createRule` of "owner = @request.auth.id" rejects any create whose
// submitted owner isn't already the auth user — the hook never gets a chance to
// fix it. Relax createRule to just "must be authenticated"; the hook then forces
// owner = the auth user on every create. Net effect: a create succeeds
// regardless of the client's owner value, and the stored owner is always the
// authenticated user. list/view/update/delete rules still scope to
// `owner = @request.auth.id`, so access is unchanged.
const owned = ["notes", "labels", "notebooks"];

migrate((app) => {
  owned.forEach((name) => {
    const c = app.findCollectionByNameOrId(name);
    c.createRule = '@request.auth.id != ""';
    app.save(c);
  });
}, (app) => {
  owned.forEach((name) => {
    const c = app.findCollectionByNameOrId(name);
    c.createRule = "owner = @request.auth.id";
    app.save(c);
  });
});
