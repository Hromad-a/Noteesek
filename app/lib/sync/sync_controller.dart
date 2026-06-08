import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../providers.dart';
import 'sync_engine.dart';

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final db = ref.watch(databaseProvider);
  final pb = ref.watch(pocketBaseProvider);
  return SyncEngine(db, pb);
});

/// Result of a sync attempt, used to drive UI feedback.
enum SyncOutcome {
  /// Synced successfully.
  ok,

  /// Not connected to any server (local-only) — nothing to do.
  notConnected,

  /// The server couldn't be reached (offline / server down). Non-fatal: the app
  /// keeps working locally.
  unreachable,

  /// The server was reached but returned an error.
  failed,

  /// A sync was already in progress.
  busy,
}

class SyncStatus {
  const SyncStatus({
    this.syncing = false,
    this.reachable = true,
    this.lastSync,
    this.message,
  });

  final bool syncing;

  /// Whether the server was reachable on the most recent attempt. False shows
  /// the "server not responding" indicator.
  final bool reachable;
  final DateTime? lastSync;
  final String? message;

  SyncStatus copyWith({
    bool? syncing,
    bool? reachable,
    DateTime? lastSync,
    String? message,
  }) =>
      SyncStatus(
        syncing: syncing ?? this.syncing,
        reachable: reachable ?? this.reachable,
        lastSync: lastSync ?? this.lastSync,
        message: message ?? this.message,
      );
}

/// Drives syncing: an initial sync + a periodic timer while connected, plus a
/// manual [syncNow]. Network failures are non-fatal — the app stays usable
/// offline and the failure is surfaced via [SyncStatus.reachable].
class SyncController extends Notifier<SyncStatus> {
  Timer? _timer;
  Timer? _debounce;

  @override
  SyncStatus build() {
    ref.onDispose(() {
      _timer?.cancel();
      _debounce?.cancel();
    });

    final connected = ref.watch(isAuthenticatedProvider);
    _timer?.cancel();
    _debounce?.cancel();
    if (connected) {
      Future.microtask(() => syncNow());
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => syncNow(),
      );
      // Push promptly after a local edit instead of waiting for the 30s tick:
      // when a dirty row appears, sync ~2s later (debounced so a burst of
      // edits collapses into one push).
      ref.listen(hasPendingChangesProvider, (_, next) {
        if (next.value == true && !state.syncing) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(seconds: 2), () => syncNow());
        }
      });
    }
    return const SyncStatus();
  }

  /// Runs a sync. [manual] attempts are surfaced to the user by the caller;
  /// periodic attempts update the indicator quietly.
  Future<SyncOutcome> syncNow({bool manual = false}) async {
    if (!ref.read(isAuthenticatedProvider)) {
      return SyncOutcome.notConnected;
    }
    if (state.syncing) return SyncOutcome.busy;

    state = state.copyWith(syncing: true, message: null);
    try {
      final ran = await ref.read(syncEngineProvider).syncOnce();
      state = SyncStatus(syncing: false, reachable: true, lastSync: DateTime.now());
      return ran ? SyncOutcome.ok : SyncOutcome.busy;
    } catch (e) {
      final unreachable = _isConnectivityError(e);
      state = state.copyWith(
        syncing: false,
        reachable: !unreachable,
        message: unreachable
            ? 'Server not responding'
            : 'Sync failed: ${_short(e)}',
      );
      return unreachable ? SyncOutcome.unreachable : SyncOutcome.failed;
    }
  }

  /// True for "can't reach the server" errors (offline, server down, DNS, TLS,
  /// timeout) as opposed to a real API error. Avoids importing dart:io so this
  /// stays web-compatible.
  bool _isConnectivityError(Object e) {
    if (e is ClientException && e.statusCode == 0) return true;
    final s = e.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('connection refused') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('connection closed') ||
        s.contains('timed out') ||
        s.contains('timeout');
  }

  String _short(Object e) {
    if (e is ClientException) {
      final msg = e.response['message'];
      if (msg is String && msg.isNotEmpty) return msg;
      return 'HTTP ${e.statusCode}';
    }
    return e.toString();
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(SyncController.new);
