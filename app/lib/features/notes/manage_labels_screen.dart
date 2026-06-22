import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import 'note_colors.dart';

/// Manage labels: create, rename, and delete. Deleting a label also removes it
/// from every note that carried it.
class ManageLabelsScreen extends ConsumerStatefulWidget {
  const ManageLabelsScreen({super.key});

  @override
  ConsumerState<ManageLabelsScreen> createState() => _ManageLabelsScreenState();
}

class _ManageLabelsScreenState extends ConsumerState<ManageLabelsScreen> {
  final _newCtrl = TextEditingController();

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _newCtrl.text.trim();
    if (name.isEmpty) return;
    await ref.read(notesRepositoryProvider).createLabel(name);
    _newCtrl.clear();
  }

  Future<void> _rename(LabelRow label) async {
    final ctrl = TextEditingController(text: label.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.renameLabel),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: context.l10n.labelName),
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
    if (name != null && name.isNotEmpty && name != label.name) {
      await ref.read(notesRepositoryProvider).renameLabel(label.id, name);
    }
  }

  Future<void> _pickColor(LabelRow label) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.labelColor,
                  style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 16),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final c in kNoteColors)
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () async {
                        await ref
                            .read(notesRepositoryProvider)
                            .setLabelColor(label.id, c.key);
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: noteSwatchFor(sheetContext, c.key),
                        child: c.key.isEmpty
                            ? const Icon(Icons.format_color_reset_outlined,
                                size: 20)
                            : (label.color == c.key
                                ? const Icon(Icons.check, size: 20)
                                : null),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(LabelRow label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.deleteEntityTitle(label.name)),
        content: Text(context.l10n.deleteLabelBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(notesRepositoryProvider).deleteLabel(label.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labelsAsync = ref.watch(labelsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.editLabels)),
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
                      hintText: context.l10n.createNewLabel,
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
            child: labelsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text(context.l10n.errorWithDetail('$e'))),
              data: (labels) {
                if (labels.isEmpty) {
                  return Center(child: Text(context.l10n.noLabelsYet));
                }
                return ListView(
                  children: [
                    for (final l in labels)
                      ListTile(
                        leading: InkWell(
                          borderRadius: BorderRadius.circular(20),
                          onTap: () => _pickColor(l),
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: noteSwatchFor(context, l.color),
                            child: Icon(
                              l.color.isEmpty
                                  ? Icons.label_outline
                                  : Icons.label,
                              size: 16,
                            ),
                          ),
                        ),
                        title: Text(l.name),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: context.l10n.rename,
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _rename(l),
                            ),
                            IconButton(
                              tooltip: context.l10n.delete,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(l),
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
