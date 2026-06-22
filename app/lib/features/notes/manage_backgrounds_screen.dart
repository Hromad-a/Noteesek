import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/notes_repository.dart';
import '../../l10n/l10n.dart';
import 'note_background.dart';

/// Settings → the image-background library. Upload images and tune their display
/// options (opacity, overlay, fit, repeat, scale); notes then pick one. Backed
/// by the `backgrounds` collection (synced).
class ManageBackgroundsScreen extends ConsumerWidget {
  const ManageBackgroundsScreen({super.key});

  Future<void> _add(WidgetRef ref) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await ref.read(notesRepositoryProvider).addBackground(bytes);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backgroundsAsync = ref.watch(backgroundsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.backgroundsTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.addBackground,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: () => _add(ref),
          ),
        ],
      ),
      body: backgroundsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            Center(child: Text(context.l10n.errorWithDetail('$e'))),
        data: (backgrounds) {
          if (backgrounds.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined,
                      size: 64, color: Theme.of(context).disabledColor),
                  const SizedBox(height: 12),
                  Text(context.l10n.noBackgroundsYet),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _add(ref),
                    icon: const Icon(Icons.add),
                    label: Text(context.l10n.addBackground),
                  ),
                ],
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 1,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: backgrounds.length,
            itemBuilder: (context, i) {
              final bg = backgrounds[i];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => _BackgroundEditSheet(id: bg.id),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: NoteBackground(
                    bg: bg,
                    child: const SizedBox.expand(),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Per-background options editor (a bottom sheet). Watches the background live so
/// the preview reflects edits; writes each change to the repository.
class _BackgroundEditSheet extends ConsumerStatefulWidget {
  const _BackgroundEditSheet({required this.id});
  final String id;

  @override
  ConsumerState<_BackgroundEditSheet> createState() =>
      _BackgroundEditSheetState();
}

class _BackgroundEditSheetState extends ConsumerState<_BackgroundEditSheet> {
  // Overrides shown while dragging a slider (so we don't write to the repo —
  // and on web hit the server — on every tick). Committed on release.
  double? _opacity, _overlay, _scale;

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    final bg = ref.watch(backgroundByIdProvider(id));
    if (bg == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final repo = ref.read(notesRepositoryProvider);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Live preview (reflects in-progress drags via the overrides).
              SizedBox(
                height: 120,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: NoteBackground(
                    bg: bg.copyWith(
                      opacity: _opacity ?? bg.opacity,
                      overlayOpacity: _overlay ?? bg.overlayOpacity,
                      scale: _scale ?? bg.scale,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _slider(l10n.bgOpacity, _opacity ?? bg.opacity, 0, 1,
                  (v) => setState(() => _opacity = v), (v) {
                repo.updateBackground(id, opacity: v);
                setState(() => _opacity = null);
              }),
              _slider(l10n.bgOverlayStrength, _overlay ?? bg.overlayOpacity, 0, 1,
                  (v) => setState(() => _overlay = v), (v) {
                repo.updateBackground(id, overlayOpacity: v);
                setState(() => _overlay = null);
              }),
              _slider(l10n.bgScale, _scale ?? bg.scale, 0.25, 3,
                  (v) => setState(() => _scale = v), (v) {
                repo.updateBackground(id, scale: v);
                setState(() => _scale = null);
              }),
              const SizedBox(height: 8),
              Text(l10n.bgOverlayColor,
                  style: Theme.of(context).textTheme.labelLarge),
              _OverlaySwatches(
                current: bg.overlayColor,
                onPick: (hex) => repo.updateBackground(id, overlayColor: hex),
              ),
              const SizedBox(height: 8),
              _ChoiceRow(
                label: l10n.bgFit,
                value: bg.fit,
                options: {
                  'cover': l10n.bgFitCover,
                  'contain': l10n.bgFitContain,
                  'fill': l10n.bgFitFill,
                  'none': l10n.bgFitNone,
                },
                onChanged: (v) => repo.updateBackground(id, fit: v),
              ),
              _ChoiceRow(
                label: l10n.bgRepeat,
                value: bg.repeat,
                options: {
                  'none': l10n.bgRepeatNone,
                  'repeat': l10n.bgRepeatTile,
                  'repeatX': l10n.bgRepeatX,
                  'repeatY': l10n.bgRepeatY,
                },
                onChanged: (v) => repo.updateBackground(id, repeat: v),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.removeBackground),
                  onPressed: () async {
                    await repo.deleteBackground(id);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max,
          ValueChanged<double> onChanged, ValueChanged<double> onChangeEnd) =>
      Row(
        children: [
          SizedBox(width: 120, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged, // local-only while dragging
              onChangeEnd: onChangeEnd, // commit to the repo on release
            ),
          ),
        ],
      );
}

/// A small palette of overlay colors (none / black / white / a few tints).
class _OverlaySwatches extends StatelessWidget {
  const _OverlaySwatches({required this.current, required this.onPick});
  final String current;
  final ValueChanged<String> onPick;

  static const _swatches = ['', '#000000', '#FFFFFF', '#534AB7', '#1D9E75'];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final hex in _swatches)
          GestureDetector(
            onTap: () => onPick(hex),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: parseHexColor(hex) ?? Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: current == hex
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                  width: current == hex ? 3 : 1,
                ),
              ),
              child: hex.isEmpty
                  ? const Icon(Icons.block, size: 18)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// A labelled dropdown of string options.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = options.containsKey(value) ? value : options.keys.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(label)),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: v,
              items: [
                for (final e in options.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (s) => s == null ? null : onChanged(s),
            ),
          ),
        ],
      ),
    );
  }
}
