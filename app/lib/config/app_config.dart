/// Static configuration and persisted-preference keys.
class AppConfig {
  /// Default PocketBase server URL shown on the login screen. Users self-host,
  /// so this is only a starting suggestion — the field is editable and the
  /// chosen value is persisted.
  static const String defaultServerUrl = 'http://localhost:8090';

  /// Owner tag for notes created while not connected to a server. These are
  /// "claimed" (reassigned to the account) when the user connects.
  static const String localOwner = 'local';

  // shared_preferences keys
  static const String kServerUrl = 'server_url';
  static const String kPbAuth = 'pb_auth';
  static const String kActiveOwner = 'active_owner';
}
