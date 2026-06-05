import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'sync_engine.dart';

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final db = ref.watch(databaseProvider);
  final pb = ref.watch(pocketBaseProvider);
  return SyncEngine(db, pb);
});

class SyncStatus {
  const SyncStatus({this.syncing = false, this.error, this.lastSync});

  final bool syncing;
  final String? error;
  final DateTime? lastSync;

  SyncStatus copyWith({bool? syncing, String? error, DateTime? lastSync}) =>
      SyncStatus(
        syncing: syncing ?? this.syncing,
        error: error,
        lastSync: lastSync ?? this.lastSync,
      );
}

/// Drives syncing: an initial sync + a periodic timer while authenticated, plus
/// a manual [syncNow]. Rebuilds (and (re)starts/stops the timer) on auth change.
class SyncController extends Notifier<SyncStatus> {
  Timer? _timer;

  @override
  SyncStatus build() {
    ref.onDispose(() => _timer?.cancel());

    final authed = ref.watch(isAuthenticatedProvider);
    _timer?.cancel();
    if (authed) {
      Future.microtask(syncNow);
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => syncNow(),
      );
    }
    return const SyncStatus();
  }

  Future<void> syncNow() async {
    if (state.syncing) return;
    state = state.copyWith(syncing: true, error: null);
    try {
      await ref.read(syncEngineProvider).syncOnce();
      state = SyncStatus(syncing: false, lastSync: DateTime.now());
    } catch (e) {
      state = SyncStatus(syncing: false, error: e.toString());
    }
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(SyncController.new);
