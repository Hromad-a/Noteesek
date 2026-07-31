import 'package:flutter/material.dart';

/// Curated set of icons a notebook can be given (chosen on the Manage Notebooks
/// screen). The map **key** is what's stored on the record — a stable string, so
/// it survives Flutter/codepoint changes and tree-shaking (never store an
/// `IconData` directly). Empty / unknown key → the default book icon.
const Map<String, IconData> kNotebookIcons = {
  'book': Icons.book_outlined,
  'work': Icons.work_outline,
  'home': Icons.home_outlined,
  'star': Icons.star_outline,
  'favorite': Icons.favorite_border,
  'shopping': Icons.shopping_cart_outlined,
  'travel': Icons.flight_outlined,
  'food': Icons.restaurant_outlined,
  'fitness': Icons.fitness_center,
  'music': Icons.music_note_outlined,
  'movie': Icons.movie_outlined,
  'code': Icons.code,
  'school': Icons.school_outlined,
  'idea': Icons.lightbulb_outline,
  'money': Icons.payments_outlined,
  'pets': Icons.pets,
  'game': Icons.sports_esports_outlined,
  'health': Icons.health_and_safety_outlined,
  'nature': Icons.park_outlined,
  'event': Icons.event_outlined,
  'flag': Icons.flag_outlined,
  'gift': Icons.card_giftcard,
  'camera': Icons.photo_camera_outlined,
  'folder': Icons.folder_outlined,
};

/// The icon shown when a notebook has no custom icon set.
const IconData kNotebookDefaultIcon = Icons.book_outlined;

/// Resolve a stored icon [key] to its [IconData], falling back to the default.
IconData notebookIconData(String key) =>
    kNotebookIcons[key] ?? kNotebookDefaultIcon;

/// Renders a notebook's icon, overlaying a small people badge in the corner when
/// the notebook is [shared] (so a custom icon still signals sharing). Used in the
/// notebook selector, its scope pills, and the Manage Notebooks list.
class NotebookIcon extends StatelessWidget {
  const NotebookIcon({
    super.key,
    required this.iconKey,
    this.shared = false,
    this.size = 20,
    this.color,
  });

  final String iconKey;
  final bool shared;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(notebookIconData(iconKey), size: size, color: color);
    if (!shared) return icon;
    // A small people glyph tucked in the corner, inheriting the icon's own
    // colour (via [color] / the ambient IconTheme) so it fits on any background
    // — no filled badge, which read as a dark blob over tonal surfaces.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -3,
          bottom: -3,
          child: Icon(Icons.people, size: size * 0.5, color: color),
        ),
      ],
    );
  }
}
