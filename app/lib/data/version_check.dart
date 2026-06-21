import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../providers.dart';

/// The app-vs-server version comparison used to warn about (and gracefully
/// explain) a client/server version mismatch.
///
/// A mismatch is the usual cause of cryptic decode errors in newer features
/// (e.g. a share endpoint whose response shape changed between releases). Rather
/// than surfacing the raw error, the UI watches [versionStatusProvider] so it
/// can show a clear "update so they match" message and a warning by the account.
class VersionStatus {
  const VersionStatus({this.appVersion, this.serverVersion});

  /// This build's version (`pubspec` `version:` minus the build number). Null
  /// when unknown (e.g. on web, where the check doesn't apply).
  final String? appVersion;

  /// The connected server's version, from `<baseUrl>/version.json`. Null when
  /// not connected or unreachable.
  final String? serverVersion;

  /// True only when both versions are known and differ. Web is served *by* the
  /// server itself, so the two can never disagree there — always false.
  bool get mismatch =>
      (appVersion?.isNotEmpty ?? false) &&
      (serverVersion?.isNotEmpty ?? false) &&
      appVersion != serverVersion;
}

/// Fetches `<baseURL>/version.json` (the Flutter web build's version manifest
/// that the server serves) and returns its `version`, or null on any failure.
Future<String?> fetchServerVersion(String baseURL) async {
  final base = baseURL.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse('$base/version.json');
  if (uri == null) return null;
  try {
    final resp = await http.get(uri).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final v = (json['version'] ?? '').toString();
    return v.isEmpty ? null : v;
  } catch (_) {
    return null;
  }
}

/// Compares this app's version with the connected server's. Meaningful only on
/// mobile while signed in (web is same-origin; signed-out mobile has no server
/// to compare against). Re-evaluates on auth/server-URL changes.
final versionStatusProvider = FutureProvider.autoDispose<VersionStatus>((ref) async {
  if (kIsWeb) return const VersionStatus();
  ref.watch(authChangesProvider);
  final pb = ref.watch(pocketBaseProvider);
  if (!pb.authStore.isValid) return const VersionStatus();

  final app = (await PackageInfo.fromPlatform()).version;
  final server = await fetchServerVersion(pb.baseURL);
  return VersionStatus(appVersion: app, serverVersion: server);
});
