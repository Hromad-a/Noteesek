import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../data/notes_repository.dart';
import '../../providers.dart';

/// A user that a notebook can be shared with (from the server directory).
class ShareableUser {
  const ShareableUser({required this.id, required this.email});
  final String id;
  final String email;
}

/// Talks to the server-only sharing endpoints. Shared notebooks require a
/// connected, signed-in account, so this always goes through PocketBase (there
/// is no local/offline equivalent — mirrors the snapshots feature).
class SharingService {
  SharingService(this._pb);
  final PocketBase _pb;

  /// All other registered users on the server (for the "share with…" picker).
  /// Backed by `GET /api/noteesek/users` (auth-gated; excludes the caller).
  Future<List<ShareableUser>> listUsers() async {
    final res = await _pb.send('/api/noteesek/users', method: 'GET');
    final raw = (res['users'] as List?) ?? const [];
    return [
      for (final u in raw)
        ShareableUser(
          id: (u as Map)['id'] as String,
          email: u['email'] as String? ?? '',
        ),
    ];
  }
}

final sharingServiceProvider = Provider<SharingService>(
    (ref) => SharingService(ref.watch(pocketBaseProvider)));

/// The server's user directory (id → email), fetched once per screen open.
/// Used to render member emails in the share sheet. Auto-disposed.
final shareableUsersProvider =
    FutureProvider.autoDispose<List<ShareableUser>>((ref) {
  return ref.watch(sharingServiceProvider).listUsers();
});

/// The member ids a notebook is shared with (decodes the JSON id array).
List<String> sharedWithIds(String rawSharedWith) => labelIdsOfRaw(rawSharedWith);

/// How long a note edit-lock stays valid without a heartbeat refresh. A lock
/// older than this is "stale" and can be taken over (covers crashes/disconnects;
/// see docs/shared-notebooks.md). The holder refreshes well within the window.
const Duration kLockExpiry = Duration(minutes: 2);
const Duration kLockHeartbeat = Duration(seconds: 25);

/// Whether a lock with this `lockedAt` ISO timestamp is still held (not stale).
/// Empty/unparseable ⇒ not held.
bool lockIsFresh(String lockedAt) {
  if (lockedAt.trim().isEmpty) return false;
  final t = DateTime.tryParse(lockedAt);
  if (t == null) return false;
  return DateTime.now().toUtc().difference(t.toUtc()) < kLockExpiry;
}
