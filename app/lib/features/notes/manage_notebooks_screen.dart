import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';

/// Manage notebooks: create, rename, and delete. The default notebook can be
/// renamed but not deleted. Deleting a notebook offers to move its notes to the
/// default notebook or send them to Trash.
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
        title: const Text('Rename notebook'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Notebook name'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Save'),
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
    // Three-way choice: move the notes to the default notebook, delete them
    // (to Trash), or cancel.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${notebook.name}"?'),
        content: const Text(
            'Choose what happens to the notes in this notebook.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('move'),
            child: const Text('Move to default'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('trash'),
            child: const Text('Delete notes'),
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
      appBar: AppBar(title: const Text('Manage notebooks')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Create new notebook',
                      prefixIcon: Icon(Icons.add),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _create(),
                  ),
                ),
                TextButton(onPressed: _create, child: const Text('Add')),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: notebooksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (notebooks) {
                if (notebooks.isEmpty) {
                  return const Center(child: Text('No notebooks yet'));
                }
                return ListView(
                  children: [
                    for (final nb in notebooks)
                      ListTile(
                        leading: Icon(
                            nb.isDefault ? Icons.book : Icons.book_outlined),
                        title: Text(nb.name),
                        subtitle: nb.isDefault ? const Text('Default') : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Rename',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _rename(nb),
                            ),
                            IconButton(
                              tooltip: nb.isDefault
                                  ? 'The default notebook can\'t be deleted'
                                  : 'Delete',
                              icon: const Icon(Icons.delete_outline),
                              onPressed:
                                  nb.isDefault ? null : () => _delete(nb),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
