/// <reference path="../pb_data/types.d.ts" />

// Configure SMTP (and the password-reset email) from environment variables on
// every boot, so mail settings live in the deploy environment (.env) rather
// than only in pb_data. Secrets never touch the repo.
//
// Required to enable mail: SMTP_HOST. Everything else has sane defaults.
//   SMTP_HOST, SMTP_PORT (587), SMTP_USERNAME, SMTP_PASSWORD,
//   SMTP_TLS ("false" → STARTTLS on 587; "true" → implicit TLS on 465),
//   SMTP_AUTH_METHOD ("PLAIN" | "LOGIN"), SMTP_LOCALNAME (Gmail relay only),
//   SMTP_SENDER_ADDRESS (defaults to SMTP_USERNAME), SMTP_SENDER_NAME,
//   APP_URL — public origin of the web app; the reset email links back here.
//
// APP_URL is optional: when unset, it's auto-derived from the request origin at
// reset time (see the request hook below) — the web app is served by this same
// server, so its origin IS the app URL. Set APP_URL explicitly only when you
// need to override that (e.g. behind a proxy that doesn't forward Host/Proto).
onBootstrap((e) => {
  // Finish the normal bootstrap first so the DB/settings are loaded.
  e.next();

  const host = $os.getenv("SMTP_HOST");
  if (!host) {
    return; // mail not configured — leave whatever is in pb_data untouched
  }

  const env = (key, fallback) => {
    const v = $os.getenv(key);
    return v === "" ? fallback : v;
  };

  const settings = $app.settings();
  settings.smtp.enabled = true;
  settings.smtp.host = host;
  settings.smtp.port = parseInt(env("SMTP_PORT", "587"), 10);
  settings.smtp.username = env("SMTP_USERNAME", "");
  settings.smtp.password = env("SMTP_PASSWORD", "");
  settings.smtp.authMethod = env("SMTP_AUTH_METHOD", "PLAIN");
  // tls=true → implicit TLS (port 465). tls=false → STARTTLS upgrade (port 587).
  settings.smtp.tls = env("SMTP_TLS", "false") === "true";
  settings.smtp.localName = env("SMTP_LOCALNAME", "");

  // Only pin appURL from env when provided; otherwise leave it for the request
  // hook to auto-derive from the actual origin at reset time.
  const appUrl = env("APP_URL", "");
  if (appUrl) {
    settings.meta.appURL = appUrl.replace(/\/+$/, "");
  }
  settings.meta.senderName = env("SMTP_SENDER_NAME", "Noteesek");
  settings.meta.senderAddress =
    env("SMTP_SENDER_ADDRESS", env("SMTP_USERNAME", "no-reply@noteesek.local"));

  $app.save(settings);

  // Point the user password-reset email at our own web app, which reads the
  // ?reset=<token> query param and shows the confirm screen. {APP_URL} and
  // {TOKEN} are PocketBase template placeholders.
  try {
    const users = $app.findCollectionByNameOrId("users");
    users.resetPasswordTemplate.subject = "Reset your Noteesek password";
    users.resetPasswordTemplate.body = [
      "<p>Hello,</p>",
      "<p>Click the button below to choose a new password. This link expires soon.</p>",
      '<p><a class="btn" href="{APP_URL}/?reset={TOKEN}" target="_blank" rel="noopener">Reset password</a></p>',
      "<p>If the button doesn't work, open the app and paste this code:</p>",
      "<p><strong>{TOKEN}</strong></p>",
      "<p>If you didn't request a password reset, you can safely ignore this email.</p>",
    ].join("\n");
    $app.save(users);
  } catch (err) {
    $app.logger().error("smtp.pb.js: failed to set reset template", "error", String(err));
  }

  $app.logger().info(
    "smtp.pb.js: SMTP configured",
    "host", host,
    "appURL", appUrl || "(auto from request)",
  );
});

// Auto-derive APP_URL from the request origin when it isn't pinned via env.
// The web app is served by this same server, so the origin the user hit IS the
// app URL the reset link should point back to. Runs just before the email is
// sent (e.next()), so the {APP_URL} placeholder resolves to the fresh value.
// Skipped entirely when APP_URL is set in env (explicit override wins).
onRecordRequestPasswordResetRequest((e) => {
  if (!$os.getenv("APP_URL") && $os.getenv("SMTP_HOST") && e.request) {
    const hdr = e.request.header;
    const proto =
      hdr.get("X-Forwarded-Proto") || (e.isTLS() ? "https" : "http");
    const host = hdr.get("X-Forwarded-Host") || e.request.host;
    if (host) {
      const origin = proto + "://" + host;
      const settings = $app.settings();
      if (settings.meta.appURL !== origin) {
        settings.meta.appURL = origin;
        $app.save(settings);
      }
    }
  }
  e.next();
}, "users");

