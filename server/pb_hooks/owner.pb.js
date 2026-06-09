/// <reference path="../pb_data/types.d.ts" />

// Reliability + defense-in-depth for sync.
//
// Stamp `owner` = the authenticated user on every create for the owner-scoped
// collections, regardless of what the client sent. This makes the createRule
// (`owner = @request.auth.id`) always pass and removes a whole class of
// "record created locally but never syncs up" bugs caused by a stale or empty
// client-side owner (e.g. a notebook/label still tagged with the offline
// `local` sentinel because a claim step was missed). The server is
// authoritative for ownership; the client's value is ignored on create.
//
// checklist_items and attachments have no `owner` field — their access derives
// from the parent note's owner via relation traversal — so they're not included.
//
// NOTE: this only takes effect because the createRule for these collections is
// relaxed to `@request.auth.id != ""` (migration 1700000011). PocketBase checks
// the createRule BEFORE this hook, so with a stricter `owner = @request.auth.id`
// rule a create with a wrong owner would be rejected before the hook could fix
// it. list/view/update/delete rules remain owner-scoped.
["notes", "labels", "notebooks"].forEach((name) => {
  onRecordCreateRequest((e) => {
    if (e.auth) {
      e.record.set("owner", e.auth.id);
    }
    e.next();
  }, name);
});
