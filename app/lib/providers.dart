import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
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
    return prefs.getString(AppConfig.kServerUrl) ??
        AppConfig.defaultServerUrl();
  }

  /// Persist and apply a new server URL.
  Future<void> set(String url) async {
    if (url == state) return;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kServerUrl, url);
    // A session is only valid against the server that issued its token. Pointing
    // at a different server invalidates it, so drop the persisted auth — the
    // rebuilt client starts unauthenticated and the user must sign in again.
    await prefs.remove(AppConfig.kPbAuth);
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

  // Globally detect an invalidated session: any API response of 401 means the
  // stored token is no longer accepted by this server (expired, or issued by a
  // different server). Clear auth so the web app falls back to the login gate
  // instead of silently showing an empty, unsyncable notes screen.
  return PocketBase(
    baseUrl,
    authStore: authStore,
    httpClientFactory: () => _AuthGuardClient(http.Client(), authStore),
  );
});

/// Wraps an [http.Client], clearing [_authStore] on any 401 response so an
/// invalid/stale token can't strand the user on a dead session.
class _AuthGuardClient extends http.BaseClient {
  _AuthGuardClient(this._inner, this._authStore);

  final http.Client _inner;
  final AuthStore _authStore;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final resp = await _inner.send(request);
    // Only react when we actually sent a token; a 401 with no auth is just a
    // normal "must log in" response (e.g. the login request itself on bad creds
    // is 400, but guard against unauthenticated calls regardless).
    if (resp.statusCode == 401 && _authStore.isValid) {
      _authStore.clear();
    }
    return resp;
  }

  @override
  void close() => _inner.close();
}

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
