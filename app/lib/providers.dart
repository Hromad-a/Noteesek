import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_config.dart';
import 'data/local/database.dart';

/// SharedPreferences instance. Overridden with the real value in main() after
/// async init, so synchronous reads work everywhere.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider not overridden'),
);

/// The local offline database. Disposed with the provider container.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Currently configured server URL (persisted). Change it via
/// `ref.read(serverUrlProvider.notifier).set(url)`.
class ServerUrlNotifier extends Notifier<String> {
  @override
  String build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(AppConfig.kServerUrl) ?? AppConfig.defaultServerUrl;
  }

  /// Persist and apply a new server URL.
  Future<void> set(String url) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kServerUrl, url);
    state = url;
  }
}

final serverUrlProvider =
    NotifierProvider<ServerUrlNotifier, String>(ServerUrlNotifier.new);

/// The PocketBase client, rebuilt whenever the server URL changes. Auth state
/// is persisted to SharedPreferences via an [AsyncAuthStore].
final pocketBaseProvider = Provider<PocketBase>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final baseUrl = ref.watch(serverUrlProvider);

  final authStore = AsyncAuthStore(
    save: (data) async => prefs.setString(AppConfig.kPbAuth, data),
    initial: prefs.getString(AppConfig.kPbAuth),
  );

  return PocketBase(baseUrl, authStore: authStore);
});

/// Emits on every auth change (login/logout/token refresh). The widget tree
/// watches this to route between the login screen and the app.
final authChangesProvider = StreamProvider<AuthStoreEvent>((ref) {
  final pb = ref.watch(pocketBaseProvider);
  return pb.authStore.onChange;
});

/// Whether a valid (logged-in) auth token currently exists. Also gates syncing:
/// no account connected ⇒ local-only ⇒ sync disabled.
final isAuthenticatedProvider = Provider<bool>((ref) {
  // Re-evaluate whenever auth changes.
  ref.watch(authChangesProvider);
  final pb = ref.watch(pocketBaseProvider);
  return pb.authStore.isValid;
});

/// The owner id stamped on locally-created notes. Defaults to the [local]
/// sentinel until the user connects a server, after which it's their user id.
class ActiveOwnerNotifier extends Notifier<String> {
  @override
  String build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getString(AppConfig.kActiveOwner) ?? AppConfig.localOwner;
  }

  Future<void> set(String owner) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kActiveOwner, owner);
    state = owner;
  }
}

final activeOwnerProvider =
    NotifierProvider<ActiveOwnerNotifier, String>(ActiveOwnerNotifier.new);
