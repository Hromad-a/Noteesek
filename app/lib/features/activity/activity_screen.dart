import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../l10n/l10n.dart';
import '../notes/note_editor_screen.dart';
import 'activity_service.dart';

/// The shared-notebook activity feed: an "Inbox" of recent changes other members
/// made to notes in notebooks you share, plus an "Archive" of older / dismissed
/// ones. Opening the screen marks everything read (clears the bell badge); a
/// snapshot of the pre-open read watermark keeps the just-unread items visually
/// flagged for this visit.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  DateTime? _seenSnapshot;

  @override
  void initState() {
    super.initState();
    // Freeze the read watermark before we mark everything read, so the entries
    // that were unread on entry stay highlighted while the screen is open.
    _seenSnapshot = ref.read(activitySeenAtProvider).value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(activityServiceProvider).markAllRead();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final partition = ref.watch(activityPartitionProvider);
    final async = ref.watch(activityEntriesProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.activityTitle),
          actions: [
            IconButton(
              tooltip: l10n.markAllRead,
              icon: const Icon(Icons.done_all),
              onPressed: () => ref.read(activityServiceProvider).markAllRead(),
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: l10n.activityInboxTab),
              Tab(text: l10n.archiveTitle),
            ],
          ),
        ),
        body: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) =>
              Center(child: Text(l10n.errorWithDetail('$e'))),
          data: (_) => TabBarView(
            children: [
              _ActivityList(
                entries: partition.inbox,
                seenSnapshot: _seenSnapshot,
                emptyText: l10n.activityEmptyInbox,
                archived: false,
              ),
              _ActivityList(
                entries: partition.archive,
                seenSnapshot: null, // no unread highlight in the archive
                emptyText: l10n.activityEmptyArchive,
                archived: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityList extends ConsumerWidget {
  const _ActivityList({
    required this.entries,
    required this.seenSnapshot,
    required this.emptyText,
    required this.archived,
  });

  final List<ActivityEntry> entries;
  final DateTime? seenSnapshot;
  final String emptyText;

  /// Whether these are already-archived entries (trailing action un-archives),
  /// vs inbox entries (trailing action archives).
  final bool archived;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (entries.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) => _ActivityTile(
        entry: entries[i],
        seenSnapshot: seenSnapshot,
        archived: archived,
      ),
    );
  }
}

class _ActivityTile extends ConsumerWidget {
  const _ActivityTile({
    required this.entry,
    required this.seenSnapshot,
    required this.archived,
  });

  final ActivityEntry entry;
  final DateTime? seenSnapshot;
  final bool archived;

  IconData get _icon => switch (entry.action) {
        'created' => Icons.add_circle_outline,
        'deleted' => Icons.delete_outline,
        _ => Icons.edit_outlined,
      };

  String _actionLabel(BuildContext context) => switch (entry.action) {
        'created' => context.l10n.activityActionCreated,
        'deleted' => context.l10n.activityActionDeleted,
        _ => context.l10n.activityActionEdited,
      };

  /// Open the note this entry refers to, if it still exists. A note that was
  /// hard-deleted (or a shared note not present on this device) can't be opened,
  /// so we surface a short message instead of a blank editor.
  Future<void> _openNote(BuildContext context, WidgetRef ref) async {
    if (entry.note.isEmpty) return;
    final repo = ref.read(notesRepositoryProvider);
    NoteRow? note;
    try {
      note = await repo
          .watchNote(entry.note)
          .first
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      note = null;
    }
    if (!context.mounted) return;
    if (note == null || note.deleted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.activityNoteUnavailable)),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: entry.note)),
    );
  }

  String _time(BuildContext context) {
    final at = entry.createdAt?.toLocal();
    if (at == null) return '';
    final ml = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final sameDay =
        now.year == at.year && now.month == at.month && now.day == at.day;
    return sameDay
        ? ml.formatTimeOfDay(TimeOfDay.fromDateTime(at))
        : ml.formatShortDate(at);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final at = entry.createdAt;
    final unread = !archived &&
        seenSnapshot != null &&
        at != null &&
        at.isAfter(seenSnapshot!);
    final title =
        entry.noteTitle.trim().isEmpty ? l10n.activityUntitledNote : entry.noteTitle;
    final actor =
        entry.actorEmail.trim().isEmpty ? l10n.activityUnknownMember : entry.actorEmail;

    return ListTile(
      onTap: () => _openNote(context, ref),
      leading: CircleAvatar(
        backgroundColor: unread
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        child: Icon(_icon,
            size: 20,
            color: unread ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
      ),
      title: Text(
        actor,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: unread ? FontWeight.w600 : null),
      ),
      subtitle: Text(
        '${_actionLabel(context)} · $title',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_time(context),
              style: TextStyle(fontSize: 12, color: scheme.outline)),
          IconButton(
            tooltip: archived ? l10n.unarchive : l10n.archive,
            icon: Icon(
                archived ? Icons.unarchive_outlined : Icons.archive_outlined,
                size: 20),
            onPressed: () {
              final svc = ref.read(activityServiceProvider);
              if (archived) {
                svc.unarchive(entry.id);
              } else {
                svc.archive(entry.id);
              }
            },
          ),
        ],
      ),
    );
  }
}
