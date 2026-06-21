import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';
import 'note_colors.dart';
import 'note_markdown_config.dart';
import 'note_selection.dart';
import 'notebook_share_sheet.dart';
import 'sharing_service.dart';

/// A single Keep-style note card shown in the grid.
class NoteCard extends ConsumerStatefulWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.onTap,
    this.isDragTarget = false,
    this.selectable = false,
    this.reorderable = false,
  });

  final NoteRow note;
  final VoidCallback onTap;

  /// True while another note is being dragged over this one.
  final bool isDragTarget;

  /// When true, long-press enters multi-select and taps toggle selection.
  /// Only the main notes grid opts in; Archive/Label screens leave it off.
  final bool selectable;

  /// When true, the card is a [LongPressDraggable] for drag-to-reorder. Only
  /// the main grid under the Custom sort opts in; under a date sort it's false
  /// so long-press selects instead of starting a (meaningless) reorder drag.
  final bool reorderable;

  @override
  ConsumerState<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends ConsumerState<NoteCard> {
  /// Set true once a long-press drag actually moves far enough to be a
  /// reorder (rather than a still long-press, which means "select"). Survives
  /// the rebuilds triggered by selection state changing mid-gesture.
  bool _dragMoved = false;

  /// True when this gesture is the one that tentatively selected the card, so
  /// turning it into a reorder should undo that selection (but never deselect
  /// a card that was already selected before the drag).
  bool _addedBySelect = false;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final isDragTarget = widget.isDragTarget;
    final theme = Theme.of(context);
    final hasTitle = note.title.trim().isNotEmpty;
    final markdownOn = ref.watch(markdownEnabledProvider);

    final selectionMode =
        widget.selectable && ref.watch(selectionModeProvider);
    final selected = widget.selectable &&
        ref.watch(noteSelectionProvider.select((s) => s.contains(note.id)));
    final selection = ref.read(noteSelectionProvider.notifier);

    // Highlight when selected; otherwise keep the drag-target border.
    final highlighted = selected || isDragTarget;

    final cardContent = Card(
      clipBehavior: Clip.antiAlias,
      color: noteColorFor(context, note.color),
      shape: highlighted
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: selectionMode ? () => selection.toggle(note.id) : widget.onTap,
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
                    (markdownOn
                        ? ClipRect(
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxHeight: 220),
                              // Non-interactive: the whole card handles the tap.
                              child: IgnorePointer(
                                child: MarkdownBlock(
                                  data: note.body,
                                  config: noteMarkdownConfig(context),
                                ),
                              ),
                            ),
                          )
                        : Text(
                            note.body,
                            style: theme.textTheme.bodyMedium,
                            maxLines: 10,
                            overflow: TextOverflow.ellipsis,
                          ))
                  else if (!hasTitle)
                    Text(
                      'Empty note',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.disabledColor),
                    ),
                  _CardLabels(note: note),
                  _CardFooter(note: note),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // Overlay a checkmark badge in the corner when this card is selected.
    final card = selected
        ? Stack(
            children: [
              cardContent,
              Positioned(
                top: 6,
                right: 6,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: theme.colorScheme.primary,
                  child: Icon(Icons.check,
                      size: 16, color: theme.colorScheme.onPrimary),
                ),
              ),
            ],
          )
        : cardContent;

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

    // Not draggable (date sort, or Archive/Label screens). Long-press still
    // enters selection where that's enabled; otherwise it's a plain card.
    if (!widget.reorderable) {
      if (!widget.selectable) return card;
      return GestureDetector(
        onLongPress: () => selection.add(note.id),
        child: card,
      );
    }

    // Web: short hold (150ms) so it feels like click-drag while still
    // letting quick taps through to InkWell.onTap.
    // Mobile: standard long-press (500ms default).
    return LongPressDraggable<String>(
      data: note.id,
      delay: kIsWeb
          ? const Duration(milliseconds: 150)
          : const Duration(milliseconds: 500),
      feedback: feedback,
      // A still long-press means "select"; the moment the finger moves far
      // enough it becomes a reorder, so we drop the just-added selection.
      onDragStarted: () {
        if (!widget.selectable) return;
        _dragMoved = false;
        _addedBySelect = !selection.isSelected(note.id);
        selection.add(note.id);
      },
      onDragUpdate: (details) {
        if (!widget.selectable || _dragMoved) return;
        if (details.delta.distance > 6) {
          _dragMoved = true;
          // It's a reorder, not a selection — undo our tentative select.
          if (_addedBySelect) selection.toggle(note.id);
        }
      },
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: kIsWeb
          ? MouseRegion(cursor: SystemMouseCursors.grab, child: card)
          : card,
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
        // When "sort checked to bottom" is on, mirror the editor: unchecked
        // items on top, checked below (each group keeps its stored order).
        // Otherwise keep the stored order as-is. Then cap the preview length.
        final ordered = ref.watch(checklistAutoSortProvider)
            ? [
                ...items.where((it) => !it.checked),
                ...items.where((it) => it.checked),
              ]
            : items;
        final preview = ordered.take(8).toList();
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
                      // Wrap long items onto a few lines, then ellipsize so the
                      // card preview stays reasonably compact.
                      maxLines: 3,
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

/// Compact label chips on a card. Shows up to 3 names, then "+N".
class _CardLabels extends ConsumerWidget {
  const _CardLabels({required this.note});

  final NoteRow note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assigned = labelIdsOf(note);
    if (assigned.isEmpty) return const SizedBox.shrink();
    final labels = ref.watch(labelsProvider).asData?.value ?? const [];
    final byId = {for (final l in labels) l.id: l};
    final visible =
        assigned.where(byId.containsKey).map((id) => byId[id]!).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final shown = visible.take(3).toList();
    final extra = visible.length - shown.length;

    Widget chip(String text, String colorKey) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: noteColorFor(context, colorKey) ??
                theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(text,
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final l in shown) chip(l.name, l.color),
          if (extra > 0) chip('+$extra', ''),
        ],
      ),
    );
  }
}

/// A "shared notebook" badge shown on a card whose notebook has members. Tapping
/// opens the member sheet. Renders nothing for notes in private notebooks.
class _SharedBadge extends ConsumerWidget {
  const _SharedBadge({required this.note});
  final NoteRow note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (note.notebook.isEmpty) return const SizedBox.shrink();
    final notebooks = ref.watch(notebooksProvider).asData?.value ?? const [];
    final nb = notebooks.cast<NotebookRow?>().firstWhere(
        (n) => n?.id == note.notebook,
        orElse: () => null);
    if (nb == null || sharedWithIds(nb.sharedWith).isEmpty) {
      return const SizedBox.shrink();
    }
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      tooltip: 'Shared notebook — tap to see members',
      icon: const Icon(Icons.group_outlined),
      onPressed: () => showNotebookShareSheet(context, ref, nb.id),
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
          _SharedBadge(note: note),
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
