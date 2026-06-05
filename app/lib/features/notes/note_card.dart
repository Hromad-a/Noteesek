import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';

/// A single Keep-style note card shown in the grid.
class NoteCard extends ConsumerWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.onTap,
    this.isDragTarget = false,
  });

  final NoteRow note;
  final VoidCallback onTap;

  /// True while another note is being dragged over this one.
  final bool isDragTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasTitle = note.title.trim().isNotEmpty;

    final cardContent = Card(
      clipBehavior: Clip.antiAlias,
      shape: isDragTarget
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _CardImage(noteId: note.id),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasTitle)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        note.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (note.type == 'checklist')
                    _ChecklistPreview(noteId: note.id)
                  else if (note.body.trim().isNotEmpty)
                    Text(
                      note.body,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 10,
                      overflow: TextOverflow.ellipsis,
                    )
                  else if (!hasTitle)
                    Text(
                      'Empty note',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.disabledColor),
                    ),
                  _CardFooter(note: note),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final feedback = Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              note.title.isEmpty ? 'Note' : note.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    );

    // Web: short hold (150ms) so it feels like click-drag while still
    // letting quick taps through to InkWell.onTap.
    // Mobile: standard long-press (500ms default).
    return LongPressDraggable<String>(
      data: note.id,
      delay: kIsWeb
          ? const Duration(milliseconds: 150)
          : const Duration(milliseconds: 500),
      feedback: feedback,
      childWhenDragging: Opacity(opacity: 0.35, child: cardContent),
      child: kIsWeb
          ? MouseRegion(cursor: SystemMouseCursors.grab, child: cardContent)
          : cardContent,
    );
  }
}

class _CardImage extends ConsumerWidget {
  const _CardImage({required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(attachmentsProvider(noteId));
    return async.maybeWhen(
      data: (items) {
        final withData = items.where((a) => a.data != null).toList();
        if (withData.isEmpty) return const SizedBox.shrink();
        return AspectRatio(
          aspectRatio: 16 / 10,
          child: Image.memory(withData.first.data!, fit: BoxFit.cover),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _ChecklistPreview extends ConsumerWidget {
  const _ChecklistPreview({required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(checklistItemsProvider(noteId));
    return itemsAsync.maybeWhen(
      data: (items) {
        if (items.isEmpty) {
          return Text('No items',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).disabledColor));
        }
        final preview = items.take(8).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final it in preview)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    it.checked
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      it.content,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: it.checked
                          ? TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: Theme.of(context).disabledColor,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            if (items.length > preview.length)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('+${items.length - preview.length} more',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _CardFooter extends ConsumerWidget {
  const _CardFooter({required this.note});

  final NoteRow note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(notesRepositoryProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            tooltip: note.pinned ? 'Unpin' : 'Pin',
            icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: () => repo.setPinned(note.id, !note.pinned),
          ),
          if (kIsWeb) ...[
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: note.archived ? 'Unarchive' : 'Archive',
              icon: Icon(note.archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined),
              onPressed: () => repo.setArchived(note.id, !note.archived),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => repo.softDelete(note.id),
            ),
          ],
        ],
      ),
    );
  }
}
