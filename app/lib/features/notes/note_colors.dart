import 'package:flutter/material.dart';

/// A selectable note background color. Stored on the note as a short, stable
/// [key] (not a hex value) so the palette can be re-tuned later without
/// migrating data, and so each color can adapt to light/dark mode.
class NoteColor {
  const NoteColor(this.key, this.label, this.light, this.dark);

  /// Persisted identifier (e.g. 'coral'). The default color is the empty key.
  final String key;

  /// Human-readable name, used for tooltips/semantics.
  final String label;

  /// Background tint in light mode.
  final Color light;

  /// Background tint in dark mode.
  final Color dark;
}

/// The curated, Keep-style palette. The first entry (empty key) is "no color"
/// and renders with the theme's default card surface.
const List<NoteColor> kNoteColors = [
  NoteColor('', 'Default', Color(0x00000000), Color(0x00000000)),
  NoteColor('coral', 'Coral', Color(0xFFFAAFA8), Color(0xFF77172E)),
  NoteColor('peach', 'Peach', Color(0xFFFFCC80), Color(0xFF692B17)),
  NoteColor('sand', 'Sand', Color(0xFFFFF8B8), Color(0xFF7C4A03)),
  NoteColor('sage', 'Sage', Color(0xFFE2F6D3), Color(0xFF264D3B)),
  NoteColor('mint', 'Mint', Color(0xFFB4DDD3), Color(0xFF0C625D)),
  NoteColor('fog', 'Fog', Color(0xFFD4E4ED), Color(0xFF256377)),
  NoteColor('storm', 'Storm', Color(0xFFAECCDC), Color(0xFF284255)),
  NoteColor('dusk', 'Dusk', Color(0xFFD3BFDB), Color(0xFF472E5B)),
  NoteColor('blush', 'Blush', Color(0xFFF6E2DD), Color(0xFF6C394F)),
  NoteColor('clay', 'Clay', Color(0xFFE9E3D4), Color(0xFF4B443A)),
];

NoteColor _byKey(String key) => kNoteColors.firstWhere(
      (c) => c.key == key,
      orElse: () => kNoteColors.first,
    );

/// The background color for [key] given the current theme, or `null` for the
/// default (no color), letting callers fall back to the theme surface.
Color? noteColorFor(BuildContext context, String key) {
  if (key.isEmpty) return null;
  final c = _byKey(key);
  return Theme.of(context).brightness == Brightness.dark ? c.dark : c.light;
}

/// A non-null swatch color for [key], used to paint palette swatches (the
/// default color shows the theme surface).
Color noteSwatchFor(BuildContext context, String key) =>
    noteColorFor(context, key) ?? Theme.of(context).colorScheme.surface;
