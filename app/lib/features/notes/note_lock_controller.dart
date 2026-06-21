import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../data/local/ids.dart';
import 'sharing_service.dart';

/// Server-authoritative edit lock for a shared note, backed by the `note_locks`
/// collection (one row per locked note, UNIQUE on `note`). Acquiring = creating
/// the row, so the database arbitrates: exactly one member wins, the rest get a
/// conflict and stay read-only — no duelling. We subscribe to the note's lock
/// row over realtime for instant state, heartbeat while we hold it, and delete
/// it on release.
///
/// Notifies listeners on every state change; the editor rebuilds off [readOnly]
/// and [otherHolder]. Decoupled from the note record, so lock churn never
/// touches note content.
class NoteLockController extends ChangeNotifier {
  NoteLockController({
    required this.pb,
    required this.noteId,
    required this.userId,
  });

  final PocketBase pb;
  final String noteId;
  final String userId;

  static const _col = 'note_locks';

  String? _myLockId; // our lock row id while we hold it
  String _holder = ''; // userId currently holding ('' = free)
  String _holderAt = ''; // holder's lockedAt
  bool _reachable = true;
  bool _ready = false; // first server response received
  bool _acquiring = false;
  bool _disposed = false;
  Timer? _heartbeat;
  UnsubscribeFunc? _unsub;

  bool get iHold => _myLockId != null;

  bool get _otherFresh =>
      _holder.isNotEmpty && _holder != userId && lockIsFresh(_holderAt);

  /// The other member's id when someone else holds a fresh lock, else null.
  String? get otherHolder => _otherFresh ? _holder : null;

  /// Read-only until we've heard from the server, or when offline, or when
  /// another member holds a fresh lock (and we don't).
  bool get readOnly =>
      !_ready || !_reachable || (_otherFresh && !iHold);

  /// Begin: subscribe for realtime updates, read the current state, try to take
  /// the lock. Idempotent-ish; call once.
  Future<void> start() async {
    try {
      _unsub = await pb.collection(_col).subscribe(
            '*',
            _onEvent,
            filter: 'note = "$noteId"',
          );
    } catch (_) {
      // Realtime optional — we still refresh on start + heartbeat keeps us fresh.
    }
    await _refresh();
    await _tryAcquire();
  }

  /// Re-check after returning from background (the subscription may have dropped
  /// and our heartbeat was suspended, so the lock may be stale or taken).
  Future<void> resume() async {
    await _refresh();
    await _tryAcquire();
  }

  void _onEvent(RecordSubscriptionEvent e) {
    if (_disposed) return;
    final rec = e.record;
    if (rec == null) return;
    if (e.action == 'delete') {
      if (rec.id == _myLockId) {
        _myLockId = null;
        _heartbeat?.cancel();
      }
      _holder = '';
      _holderAt = '';
      notifyListeners();
      _tryAcquire(); // free now — take it
      return;
    }
    _holder = rec.getStringValue('lockedBy');
    _holderAt = rec.getStringValue('lockedAt');
    if (_holder == userId) {
      _myLockId = rec.id;
    } else if (_myLockId != null && rec.id != _myLockId) {
      // Someone else holds it now (our stale lock was taken over) — yield.
      _myLockId = null;
      _heartbeat?.cancel();
    }
    notifyListeners();
  }

  Future<void> _refresh() async {
    try {
      final rec = await pb.collection(_col).getFirstListItem('note = "$noteId"');
      _reachable = true;
      _holder = rec.getStringValue('lockedBy');
      _holderAt = rec.getStringValue('lockedAt');
      if (_holder == userId) _myLockId = rec.id;
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        _reachable = true; // server reached, just no lock → free
        _holder = '';
        _holderAt = '';
      } else if (e.statusCode == 0) {
        _reachable = false;
      }
    } catch (_) {
      _reachable = false;
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> _tryAcquire() async {
    if (_disposed || _acquiring || iHold || userId.isEmpty) return;
    if (_otherFresh) return; // don't steal a live lock
    _acquiring = true;
    try {
      final rec = await pb.collection(_col).create(body: {
        'note': noteId,
        'lockedBy': userId,
        'lockedAt': pbNow(),
      });
      _reachable = true;
      _myLockId = rec.id;
      _holder = userId;
      _holderAt = rec.getStringValue('lockedAt');
      _startHeartbeat();
    } on ClientException catch (e) {
      if (e.statusCode == 0) {
        _reachable = false;
      } else {
        // Create lost the race (UNIQUE) or the existing lock is stale.
        await _refresh();
        if (_holder.isNotEmpty &&
            _holder != userId &&
            !lockIsFresh(_holderAt)) {
          await _takeOverStale();
        }
      }
    } catch (_) {
      _reachable = false;
    } finally {
      _acquiring = false;
      _ready = true;
      notifyListeners();
    }
  }

  Future<void> _takeOverStale() async {
    try {
      final rec = await pb.collection(_col).getFirstListItem('note = "$noteId"');
      if (rec.getStringValue('lockedBy') == userId ||
          lockIsFresh(rec.getStringValue('lockedAt'))) {
        return; // someone refreshed/took it first
      }
      await pb.collection(_col).delete(rec.id);
      final mine = await pb.collection(_col).create(body: {
        'note': noteId,
        'lockedBy': userId,
        'lockedAt': pbNow(),
      });
      _myLockId = mine.id;
      _holder = userId;
      _holderAt = mine.getStringValue('lockedAt');
      _startHeartbeat();
    } catch (_) {
      // Lost the takeover race — stay read-only; the winner holds it.
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(kLockHeartbeat, (_) => _beat());
  }

  Future<void> _beat() async {
    final id = _myLockId;
    if (id == null) return;
    try {
      await pb.collection(_col).update(id, body: {'lockedAt': pbNow()});
      _reachable = true;
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        // Our row was deleted (stale takeover) — we no longer hold it.
        _myLockId = null;
        _heartbeat?.cancel();
        notifyListeners();
        await _refresh();
      } else if (e.statusCode == 0) {
        _reachable = false;
        notifyListeners();
      }
    } catch (_) {/* transient */}
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    final id = _myLockId;
    _myLockId = null;
    // Best-effort cleanup; runs to completion even as the widget tears down.
    () async {
      try {
        _unsub?.call();
      } catch (_) {}
      if (id != null) {
        try {
          await pb.collection(_col).delete(id);
        } catch (_) {}
      }
    }();
    super.dispose();
  }
}
