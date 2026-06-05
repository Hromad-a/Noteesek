/// Static configuration and persisted-preference keys.
class AppConfig {
  /// Default PocketBase server URL shown on the login screen. Users self-host,
  /// so this is only a starting suggestion — the field is editable and the
  /// chosen value is persisted.
  static const String defaultServerUrl = 'http://localhost:8090';

  // shared_preferences keys
  static const String kServerUrl = 'server_url';
  static const String kPbAuth = 'pb_auth';
}
