import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/app_config.dart';
import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../data/version_check.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import 'sharing_service.dart';

/// Error display for a failed directory load. A client/server version mismatch
/// is the likely culprit behind an otherwise-cryptic decode error here, so when
/// one is detected we explain that instead of dumping the raw exception.
Widget _loadError(WidgetRef ref, String prefix, Object error) {
  final mismatch = ref.watch(versionStatusProvider).value?.mismatch ?? false;
  if (mismatch) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              color: Colors.orange.shade700, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'This app and your server are running different versions. Update '
              'Noteesek on this device or your server so they match, then try '
              'again.',
            ),
          ),
        ],
      ),
    );
  }
  return Padding(
    padding: const EdgeInsets.all(8),
    child: Text('$prefix: $error'),
  );
}

/// Opens the "who is this shared with" sheet for a notebook. The owner can
/// add/remove members inline; everyone else sees a read-only member list. The
/// first time it's opened, a one-time explainer of how shared notebooks work is
/// shown.
Future<void> showNotebookShareSheet(
    BuildContext context, WidgetRef ref, String notebookId) async {
  final prefs = ref.read(sharedPreferencesProvider);
  if (!(prefs.getBool(AppConfig.kSharedNotebookIntroSeen) ?? false)) {
    await _showSharedNotebookIntro(context);
    await prefs.setBool(AppConfig.kSharedNotebookIntroSeen, true);
    if (!context.mounted) return;
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ShareSheet(notebookId: notebookId),
  );
}

/// One-time dialog explaining how shared notebooks behave.
Future<void> _showSharedNotebookIntro(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  Widget point(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.group_outlined),
      title: const Text('Sharing a notebook'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          point(Icons.edit_outlined,
              'Everyone you add can view and edit every note in this notebook.'),
          point(Icons.lock_outline,
              'One person edits a note at a time — others see it live, read-only, '
              'until it’s free.'),
          point(Icons.cloud_outlined,
              'Shared notes are online-only: editing needs a connection to your '
              'server.'),
          point(Icons.shield_outlined,
              'Only you, the owner, control who it’s shared with.'),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Got it'),
        ),
      ],
    ),
  );
}

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.notebookId});
  final String notebookId;
  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  bool _busy = false;

  Future<void> _setMembers(List<String> ids) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(notesRepositoryProvider)
          .setNotebookSharedWith(widget.notebookId, ids);
      // On mobile the change is a dirty local row — push it now so the other
      // members see it promptly (sharing is a server-connected operation).
      if (!kIsWeb) {
        await ref.read(syncControllerProvider.notifier).syncNow(manual: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not update sharing: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
    final nb = notebooks.cast<NotebookRow?>().firstWhere(
        (n) => n?.id == widget.notebookId,
        orElse: () => null);
    final me = ref.watch(authUserIdProvider);

    if (nb == null) {
      return const Padding(
        padding: EdgeInsets.all(24), child: Text('Notebook not found.'));
    }
    final members = sharedWithIds(nb.sharedWith);
    final isOwner = nb.owner == me && me.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 4,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.group_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    members.isEmpty ? 'Share "${nb.name}"' : 'Shared · ${nb.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_busy)
                  const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isOwner
                  ? 'Members can view and edit every note in this notebook. Only you can change who it’s shared with.'
                  : 'You’re a member of this shared notebook. Only the owner can change sharing.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: isOwner
                  ? _OwnerPicker(
                      members: members,
                      busy: _busy,
                      onChanged: _setMembers,
                    )
                  : _MemberList(ownerId: nb.owner, members: members),
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only view for non-owners: the owner + the members, by email.
class _MemberList extends ConsumerWidget {
  const _MemberList({required this.ownerId, required this.members});
  final String ownerId;
  final List<String> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = ref.watch(shareableUsersProvider);
    return dir.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator())),
      error: (e, _) => _loadError(ref, 'Could not load members', e),
      data: (users) {
        final byId = {for (final u in users) u.id: u.email};
        final me = ref.watch(authUserIdProvider);
        String label(String id) =>
            id == me ? '${byId[id] ?? 'You'} (you)' : (byId[id] ?? id);
        return ListView(
          shrinkWrap: true,
          children: [
            _tile(context, Icons.star_outline,
                '${byId[ownerId] ?? 'Owner'} · owner'),
            for (final m in members)
              if (m != ownerId) _tile(context, Icons.person_outline, label(m)),
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, IconData icon, String text) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 20),
        title: Text(text),
      );
}

/// Owner view: every other registered user with a checkbox = member or not.
class _OwnerPicker extends ConsumerStatefulWidget {
  const _OwnerPicker(
      {required this.members, required this.busy, required this.onChanged});
  final List<String> members;
  final bool busy;
  final ValueChanged<List<String>> onChanged;
  @override
  ConsumerState<_OwnerPicker> createState() => _OwnerPickerState();
}

class _OwnerPickerState extends ConsumerState<_OwnerPicker> {
  String _query = '';

  void _toggle(String id, bool on) {
    final next = [...widget.members];
    if (on) {
      if (!next.contains(id)) next.add(id);
    } else {
      next.remove(id);
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final dir = ref.watch(shareableUsersProvider);
    return dir.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator())),
      error: (e, _) => _loadError(ref, 'Could not load users', e),
      data: (users) {
        final q = _query.trim().toLowerCase();
        final shown = q.isEmpty
            ? users
            : users.where((u) => u.email.toLowerCase().contains(q)).toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Search people by email',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: users.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No other users are registered on this server yet.'))
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final u in shown)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: widget.members.contains(u.id),
                            onChanged: widget.busy
                                ? null
                                : (v) => _toggle(u.id, v ?? false),
                            title: Text(u.email,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
