import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../data/local/ids.dart';
import '../../providers.dart';

/// One entry in a shared notebook's activity feed: a single change another
/// member made to a note. Mirrors the server `notebook_activity` collection
/// (server-written; the client only reads). See
/// `server/pb_migrations/1700000027_create_activity.js`.
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.notebook,
    required this.note,
    required this.actorEmail,
    required this.action,
    required this.noteTitle,
    required this.created,
  });

  final String id;
  final String notebook;
  final String note;
  final String actorEmail;

  /// 'created' | 'edited' | 'deleted'.
  final String action;

  /// The note's title snapshotted at the time (may be empty / stale).
  final String noteTitle;

  /// PocketBase `created` timestamp string (e.g. "2026-06-05 00:14:58.581Z").
  final String created;

  DateTime? get createdAt => parsePbTime(created);

  factory ActivityEntry.fromRecord(RecordModel r) => ActivityEntry(
        id: r.id,
        notebook: r.getStringValue('notebook'),
        note: r.getStringValue('note'),
        actorEmail: r.getStringValue('actorEmail'),
        action: r.getStringValue('action'),
        noteTitle: r.getStringValue('noteTitle'),
        created: r.getStringValue('created'),
      );
}

/// After this long, an unarchived entry falls out of the inbox into the archive
/// automatically — derived from its age, so nothing is pruned or lost.
const Duration kActivityAutoArchiveAfter = Duration(days: 7);

/// Parse a PocketBase timestamp ("2026-06-05 00:14:58.581Z") to a [DateTime],
/// or null if empty/unparseable.
DateTime? parsePbTime(String s) {
  if (s.trim().isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

/// An entry is archived (out of the inbox) when the user manually archived it,
/// or when it's older than [kActivityAutoArchiveAfter] relative to [now].
bool activityIsArchived(
  ActivityEntry e,
  Set<String> manuallyArchived,
  DateTime now,
) {
  if (manuallyArchived.contains(e.id)) return true;
  final at = e.createdAt;
  if (at == null) return false;
  return now.difference(at) >= kActivityAutoArchiveAfter;
}

/// Split [entries] into (inbox, archive) given the manually-archived ids and the
/// current time. Inbox = recent and not manually archived; archive = the rest.
/// Both keep the input order (callers pass newest-first).
({List<ActivityEntry> inbox, List<ActivityEntry> archive}) partitionActivity(
  List<ActivityEntry> entries,
  Set<String> manuallyArchived,
  DateTime now,
) {
  final inbox = <ActivityEntry>[];
  final archive = <ActivityEntry>[];
  for (final e in entries) {
    (activityIsArchived(e, manuallyArchived, now) ? archive : inbox).add(e);
  }
  return (inbox: inbox, archive: archive);
}

/// How many inbox entries are newer than the read watermark [seenAt] (all of
/// them when the user has never marked the feed read).
int unreadActivityCount(List<ActivityEntry> inbox, DateTime? seenAt) {
  if (seenAt == null) return inbox.length;
  var n = 0;
  for (final e in inbox) {
    final at = e.createdAt;
    if (at != null && at.isAfter(seenAt)) n++;
  }
  return n;
}

/// Server-backed operations for the activity feed: the read watermark
/// (`activity_seen`, one row per user) and manual archive marks
/// (`activity_archives`, one sparse row per archived entry). Feed rows
/// themselves are written only by the server hook.
class ActivityService {
  ActivityService(this._pb);
  final PocketBase _pb;

  String get _me => _pb.authStore.record?.id ?? '';

  /// Mark the whole feed read up to now (upsert the user's watermark row).
  Future<void> markAllRead() async {
    final me = _me;
    if (me.isEmpty) return;
    final now = pbNow();
    try {
      final existing = await _pb
          .collection('activity_seen')
          .getFirstListItem('owner = "$me"');
      await _pb
          .collection('activity_seen')
          .update(existing.id, body: {'seenAt': now});
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        await _pb.collection('activity_seen').create(
            body: {'id': newPbId(), 'owner': me, 'seenAt': now});
      } else {
        rethrow;
      }
    }
  }

  /// Archive one entry for this user (idempotent).
  Future<void> archive(String activityId) async {
    final me = _me;
    if (me.isEmpty) return;
    try {
      await _pb.collection('activity_archives').create(body: {
        'id': newPbId(),
        'owner': me,
        'activity': activityId,
      });
    } on ClientException catch (e) {
      // 400 = the UNIQUE(owner, activity) index rejected a duplicate: already
      // archived, nothing to do.
      if (e.statusCode != 400) rethrow;
    }
  }

  /// Un-archive one entry for this user (idempotent).
  Future<void> unarchive(String activityId) async {
    final me = _me;
    if (me.isEmpty) return;
    try {
      final row = await _pb
          .collection('activity_archives')
          .getFirstListItem('owner = "$me" && activity = "$activityId"');
      await _pb.collection('activity_archives').delete(row.id);
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow; // 404 = not archived, nothing to do
    }
  }
}

final activityServiceProvider = Provider<ActivityService>(
    (ref) => ActivityService(ref.watch(pocketBaseProvider)));

/// Builds a live list from a PocketBase collection: an initial fetch plus a
/// realtime subscription that re-fetches on any change. Emits `const []` (and
/// does no network work) when signed out — the feed is a server-only feature.
Stream<List<T>> _liveCollection<T>(
  Ref ref, {
  required String collection,
  required String? filter,
  required String sort,
  required T Function(RecordModel) build,
}) {
  if (!ref.watch(isAuthenticatedProvider)) {
    return Stream.value(const []);
  }
  final pb = ref.watch(pocketBaseProvider);
  final controller = StreamController<List<T>>();
  UnsubscribeFunc? unsub;

  Future<void> reload() async {
    try {
      final rows = await pb
          .collection(collection)
          .getFullList(filter: filter, sort: sort);
      if (!controller.isClosed) controller.add(rows.map(build).toList());
    } catch (e, st) {
      if (!controller.isClosed) controller.addError(e, st);
    }
  }

  unawaited(() async {
    await reload();
    try {
      unsub = await pb
          .collection(collection)
          .subscribe('*', (_) => reload(), filter: filter);
    } catch (_) {
      // Realtime is best-effort; the initial fetch already populated the list.
    }
  }());

  ref.onDispose(() {
    unsub?.call();
    controller.close();
  });
  return controller.stream;
}

/// The feed entries visible to the current user (others' changes in notebooks
/// they're a member of), newest first. Excludes the user's own actions.
final activityEntriesProvider =
    StreamProvider.autoDispose<List<ActivityEntry>>((ref) {
  final me = ref.watch(authUserIdProvider);
  return _liveCollection<ActivityEntry>(
    ref,
    collection: 'notebook_activity',
    filter: me.isEmpty ? null : 'actor != "$me"',
    sort: '-created',
    build: ActivityEntry.fromRecord,
  );
});

/// The user's read watermark (null until they've marked the feed read once).
final activitySeenAtProvider = StreamProvider.autoDispose<DateTime?>((ref) {
  final me = ref.watch(authUserIdProvider);
  final rows = _liveCollection<DateTime?>(
    ref,
    collection: 'activity_seen',
    filter: me.isEmpty ? null : 'owner = "$me"',
    sort: '-seenAt',
    build: (r) => parsePbTime(r.getStringValue('seenAt')),
  );
  return rows.map((list) => list.isEmpty ? null : list.first);
});

/// The set of activity ids this user has manually archived.
final activityArchivedIdsProvider =
    StreamProvider.autoDispose<Set<String>>((ref) {
  final me = ref.watch(authUserIdProvider);
  final rows = _liveCollection<String>(
    ref,
    collection: 'activity_archives',
    filter: me.isEmpty ? null : 'owner = "$me"',
    sort: '-created',
    build: (r) => r.getStringValue('activity'),
  );
  return rows.map((ids) => ids.toSet());
});

/// (inbox, archive) partition of the feed, recomputed as entries or archive
/// marks change. `now` is read once per rebuild.
final activityPartitionProvider = Provider.autoDispose<
    ({List<ActivityEntry> inbox, List<ActivityEntry> archive})>((ref) {
  final entries = ref.watch(activityEntriesProvider).value ?? const [];
  final archived = ref.watch(activityArchivedIdsProvider).value ?? const {};
  return partitionActivity(entries, archived, DateTime.now());
});

/// Unread badge count: inbox entries newer than the read watermark.
final activityUnreadCountProvider = Provider.autoDispose<int>((ref) {
  final inbox = ref.watch(activityPartitionProvider).inbox;
  final seenAt = ref.watch(activitySeenAtProvider).value;
  return unreadActivityCount(inbox, seenAt);
});
