/// <reference path="../pb_data/types.d.ts" />

// Long-lived sessions: extend the users auth-token lifetime to 1 year so the
// app never logs you out just because time passed (e.g. not opening it for a
// week+). PocketBase JWTs are stateless with a fixed expiry, so this duration
// is the only thing that bounds a session by time.
//
// A session still ends the moment the account's password is changed (or "sign
// out everywhere" is used): both rotate the record's tokenKey, which
// invalidates every previously-issued token immediately, regardless of expiry.
// That is the one intended logout path — the client detects the resulting 401,
// clears the session, and shows a "you've been signed out" prompt.
//
// Trade-off: a leaked token stays valid for up to a year (until the password is
// changed). Acceptable for a self-hosted notes app; capped at 1 year rather
// than "effectively never".
const ONE_YEAR_SECONDS = 31536000; // 365 * 24 * 60 * 60
const DEFAULT_SECONDS = 604800; // PocketBase default: 7 days

migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  users.authToken.duration = ONE_YEAR_SECONDS;
  app.save(users);
}, (app) => {
  const users = app.findCollectionByNameOrId("users");
  users.authToken.duration = DEFAULT_SECONDS;
  app.save(users);
});
