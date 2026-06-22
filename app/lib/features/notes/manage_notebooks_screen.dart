import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import 'notebook_share_sheet.dart';
import 'sharing_service.dart';

/// Manage notebooks: create, rename, and delete. Deleting a notebook offers to
/// move its notes out to "No notebook" (uncategorized) or send them to Trash.
class ManageNotebooksScreen extends ConsumerStatefulWidget {
  const ManageNotebooksScreen({super.key});

  @override
  ConsumerState<ManageNotebooksScreen> createState() =>
      _ManageNotebooksScreenState();
}

class _ManageNotebooksScreenState extends ConsumerState<ManageNotebooksScreen> {
  final _newCtrl = TextEditingController();

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _newCtrl.text.trim();
    if (name.isEmpty) return;
    await ref.read(notesRepositoryProvider).createNotebook(name);
    _newCtrl.clear();
  }

  Future<void> _rename(NotebookRow notebook) async {
    final ctrl = TextEditingController(text: notebook.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.renameNotebook),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: context.l10n.notebookName),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty && name != notebook.name) {
      await ref.read(notesRepositoryProvider).renameNotebook(notebook.id, name);
    }
  }

  Future<void> _delete(NotebookRow notebook) async {
    // Three-way choice: move the notes out to "No notebook", delete them
    // (to Trash), or cancel.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.deleteEntityTitle(notebook.name)),
        content: const Text(
            'Choose what happens to the notes in this notebook.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('move'),
            child: Text(context.l10n.keepNotes),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('trash'),
            child: Text(context.l10n.deleteNotes),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await ref.read(notesRepositoryProvider).deleteNotebook(
          notebook.id,
          moveNotesToDefault: choice == 'move',
        );
  }

  @override
  Widget build(BuildContext context) {
    final notebooksAsync = ref.watch(notebooksProvider);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.manageNotebooks)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCtrl,
                    decoration: InputDecoration(
                      hintText: context.l10n.createNewNotebook,
                      prefixIcon: Icon(Icons.add),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _create(),
                  ),
                ),
                TextButton(onPressed: _create, child: Text(context.l10n.add)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: notebooksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(context.l10n.errorWithDetail('$e'))),
              data: (notebooks) {
                if (notebooks.isEmpty) {
                  return Center(child: Text(context.l10n.noNotebooksYet));
                }
                final me = ref.watch(authUserIdProvider);
                final canShare = ref.watch(isAuthenticatedProvider);
                return ListView(
                  children: [
                    for (final nb in notebooks)
                      _notebookTile(context, ref, nb, me, canShare),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// A notebook row. Owner-only actions (visibility/rename/delete) are hidden for
  /// notebooks shared *to* this user by someone else; a "Share" button (which
  /// opens the members sheet) shows whenever a server is connected. Mobile-local
  /// notebooks (owner sentinel `local`, no signed-in user) are always "owned".
  Widget _notebookTile(BuildContext context, WidgetRef ref, NotebookRow nb,
      String me, bool canShare) {
    final shared = sharedWithIds(nb.sharedWith).isNotEmpty;
    final ownedByMe = me.isEmpty || nb.owner == me;
    final locallyHidden = ref.watch(locallyHiddenNotebooksProvider);
    return ListTile(
      leading: Icon(shared ? Icons.group_outlined : Icons.book_outlined),
      title: Text(nb.name),
      subtitle: shared && !ownedByMe ? Text(context.l10n.sharedWithYou) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canShare)
            IconButton(
              tooltip: ownedByMe ? 'Share' : 'Members',
              icon: Icon(shared ? Icons.group : Icons.person_add_alt_outlined),
              onPressed: () => showNotebookShareSheet(context, ref, nb.id),
            ),
          // Members (non-owners) can't write the owner's global visibility flag,
          // so they hide a shared notebook from their own "All notes" locally.
          if (!ownedByMe)
            IconButton(
              tooltip: locallyHidden.contains(nb.id)
                  ? 'Hidden from your All notes'
                  : 'Shown in your All notes',
              icon: Icon(locallyHidden.contains(nb.id)
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () => ref
                  .read(locallyHiddenNotebooksProvider.notifier)
                  .toggle(nb.id),
            ),
          if (ownedByMe) ...[
            IconButton(
              tooltip: nb.hiddenFromAll
                  ? 'Hidden from All notes'
                  : 'Shown in All notes',
              icon: Icon(nb.hiddenFromAll
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined),
              onPressed: () => ref
                  .read(notesRepositoryProvider)
                  .setNotebookVisibility(nb.id, !nb.hiddenFromAll),
            ),
            IconButton(
              tooltip: context.l10n.rename,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _rename(nb),
            ),
            IconButton(
              tooltip: context.l10n.delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(nb),
            ),
          ],
        ],
      ),
    );
  }
}
