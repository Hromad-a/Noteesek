import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_config.dart';
import 'data/local/database.dart';

/// Whether the device has any network right now (instant, event-driven). Used to
/// gate online-only actions like adding to a shared notebook. Not a server-
/// reachability check — just "is there a network" — and assumes online if the
/// platform check fails.
final hasNetworkProvider = StreamProvider<bool>((ref) async* {
  bool online(List<ConnectivityResult> r) =>
      r.any((x) => x != ConnectivityResult.none);
  try {
    yield online(await Connectivity().checkConnectivity());
  } catch (_) {
    yield true;
  }
  yield* Connectivity().onConnectivityChanged.map(online);
});

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

/// True while any local change hasn't been pushed to the server yet (a `dirty`
/// row exists). Mobile only — never read on web (no local DB). Drives the
/// "changes not synced" sync indicator.
final hasPendingChangesProvider = StreamProvider<bool>((ref) {
  return ref.watch(databaseProvider).watchHasPending();
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

/// The signed-in user's id (empty when signed out), recomputed on every auth
/// change. Because a `Provider` only notifies dependents when its value
/// actually changes, this stays stable across token refreshes but flips when
/// the *account* changes — which the web repository keys on so it never shows a
/// previous session's cached notes.
final authUserIdProvider = Provider<String>((ref) {
  ref.watch(authChangesProvider);
  final pb = ref.watch(pocketBaseProvider);
  return pb.authStore.record?.id ?? '';
});

/// On web, a password-reset token captured from the launch URL (`?reset=…`),
/// set when the user opens the link from a reset email. Routes the app to the
/// reset-confirm screen ahead of the login gate. Null on mobile or when absent;
/// [clear] it once the reset flow is done so the app returns to login.
class PendingResetTokenNotifier extends Notifier<String?> {
  @override
  String? build() {
    if (!kIsWeb) return null;
    final token = Uri.base.queryParameters['reset'];
    return (token != null && token.isNotEmpty) ? token : null;
  }

  void clear() => state = null;
}

final pendingResetTokenProvider =
    NotifierProvider<PendingResetTokenNotifier, String?>(
        PendingResetTokenNotifier.new);

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

/// The app's light/dark/system theme preference (persisted, global). Drives
/// [MaterialApp.themeMode]; defaults to following the system.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return switch (prefs.getString(AppConfig.kThemeMode)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(AppConfig.kThemeMode, mode.name);
    state = mode;
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// Whether the one-time first-run intro has been shown (mobile). Persisted.
class OnboardingSeenNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPreferencesProvider).getBool(AppConfig.kSeenOnboarding) ??
      false;

  Future<void> markSeen() async {
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConfig.kSeenOnboarding, true);
    state = true;
  }
}

final onboardingSeenProvider =
    NotifierProvider<OnboardingSeenNotifier, bool>(OnboardingSeenNotifier.new);
