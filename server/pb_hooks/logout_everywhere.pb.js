/// <reference path="../pb_data/types.d.ts" />

// "Sign out of all devices": rotate the caller's auth tokenKey, which
// invalidates every JWT ever issued to this account (on every device), then
// return a fresh token so the device that made the request stays signed in.
//
// PocketBase JWTs are stateless and signed per-record with tokenKey, so
// refreshing the key is the canonical way to revoke all sessions at once
// without per-device tracking.
routerAdd(
  "POST",
  "/api/noteesek/logout-everywhere",
  (e) => {
    if (!e.auth) {
      throw new UnauthorizedError("Not authenticated.");
    }
    // Load the full record (so the hidden tokenKey field is present) before
    // rotating + saving it.
    const record = $app.findRecordById(e.auth.collection().id, e.auth.id);
    record.refreshTokenKey();
    $app.save(record);
    return e.json(200, { token: record.newAuthToken() });
  },
  $apis.requireAuth(),
);
