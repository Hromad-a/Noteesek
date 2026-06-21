/// <reference path="../pb_data/types.d.ts" />

// Shared notebooks (phase 1) — a minimal user directory for the "share with…"
// picker. The `users` collection isn't listable by other accounts, so this
// auth-gated route returns the id + email of every other registered user so the
// owner can pick members (and the client can resolve an email → id for
// notebooks.sharedWith).
//
// DECISION (see docs/shared-notebooks.md): exposing registered emails to any
// signed-in user is accepted for trusted self-hosted servers — no extra gating.
// The caller is excluded from the result.
routerAdd(
  "GET",
  "/api/noteesek/users",
  (e) => {
    if (!e.auth) throw new UnauthorizedError("Not authenticated.");
    const me = e.auth.id;

    // All users except the caller. Kept simple (no pagination): the directory is
    // small on a self-hosted instance.
    const records = $app.findRecordsByFilter(
      "users", "id != {:me}", "email", 0, 0, { me });

    const users = records.map((r) => ({
      id: r.id,
      email: r.getString("email"),
    }));
    return e.json(200, { users });
  },
  $apis.requireAuth(),
);
