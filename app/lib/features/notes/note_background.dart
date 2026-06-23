import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/database.dart';
import '../../data/notes_repository.dart';

/// Display-option enums mirrored from CSS-like names stored on a [BackgroundRow].
BoxFit boxFitFor(String fit) => switch (fit) {
      'contain' => BoxFit.contain,
      'fill' => BoxFit.fill,
      'none' => BoxFit.none,
      _ => BoxFit.cover,
    };

ImageRepeat imageRepeatFor(String repeat) => switch (repeat) {
      'repeat' => ImageRepeat.repeat,
      'repeatX' => ImageRepeat.repeatX,
      'repeatY' => ImageRepeat.repeatY,
      _ => ImageRepeat.noRepeat,
    };

const List<String> kBackgroundFits = ['cover', 'contain', 'fill', 'none'];
const List<String> kBackgroundRepeats = [
  'none',
  'repeat',
  'repeatX',
  'repeatY'
];

/// Parse a `#RRGGBB` / `RRGGBB` (or `#AARRGGBB`) hex string to a [Color].
/// Returns null for empty/invalid input.
Color? parseHexColor(String hex) {
  var h = hex.trim().replaceFirst('#', '');
  if (h.isEmpty) return null;
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Looks up a single background by id for *rendering* — from the full local
/// pool (own library + foreign backgrounds fetched for shared notes).
final backgroundByIdProvider =
    Provider.family<BackgroundRow?, String>((ref, id) {
  if (id.isEmpty) return null;
  final list = ref.watch(allBackgroundsProvider).asData?.value ?? const [];
  for (final b in list) {
    if (b.id == id) return b;
  }
  return null;
});

/// Paints [bg]'s image + overlay behind [child]. The child sizes the layer; the
/// image/overlay fill it. Falls back to just [child] when the background has no
/// bytes yet (e.g. still downloading).
class NoteBackground extends StatelessWidget {
  const NoteBackground({super.key, required this.bg, required this.child});

  final BackgroundRow? bg;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final b = bg;
    final bytes = b?.data;
    if (b == null || bytes == null) return child;
    final overlay = parseHexColor(b.overlayColor)
        ?.withValues(alpha: b.overlayOpacity.clamp(0.0, 1.0));
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: MemoryImage(bytes),
                fit: boxFitFor(b.fit),
                repeat: imageRepeatFor(b.repeat),
                scale: b.scale <= 0 ? 1.0 : b.scale,
                opacity: b.opacity.clamp(0.0, 1.0),
              ),
            ),
          ),
        ),
        if (overlay != null) Positioned.fill(child: ColoredBox(color: overlay)),
        child,
      ],
    );
  }
}
