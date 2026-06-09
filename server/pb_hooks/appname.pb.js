/// <reference path="../pb_data/types.d.ts" />

// Set the application name on every boot so system emails (login alerts,
// password reset, verification) are branded "Noteesek" instead of PocketBase's
// default "Acme" placeholder. The name also shows in the admin dashboard.
//
// Defaults to "Noteesek"; override with the APP_NAME env var. Runs regardless
// of SMTP config (unlike smtp.pb.js), and only writes when the value actually
// changes to avoid a needless settings save on every start.
onBootstrap((e) => {
  // Finish the normal bootstrap first so settings are loaded.
  e.next();

  const envName = $os.getenv("APP_NAME");
  const appName = envName === "" ? "Noteesek" : envName;

  const settings = $app.settings();
  if (settings.meta.appName !== appName) {
    settings.meta.appName = appName;
    $app.save(settings);
    $app.logger().info("appname.pb.js: appName set", "appName", appName);
  }
});
