import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// Shared Markdown rendering config for note previews and cards.
///
/// `markdown_widget`'s default config only distinguishes H1–H3 (H4, H5 and H6
/// all render at body size, 16px), so `####`/`#####`/`######` look like normal
/// text. This overrides every heading level with a distinct, descending size so
/// `#` … `######` read as properly nested headings, while keeping the package
/// defaults for everything else (paragraphs, code, quotes, …) and honouring
/// dark/light mode.
MarkdownConfig noteMarkdownConfig(BuildContext context) {
  final theme = Theme.of(context);
  final base = theme.brightness == Brightness.dark
      ? MarkdownConfig.darkConfig
      : MarkdownConfig.defaultConfig;
  final color = theme.colorScheme.onSurface;
  TextStyle h(double size) => TextStyle(
        fontSize: size,
        fontWeight: FontWeight.bold,
        color: color,
        height: 1.3,
      );
  return base.copy(configs: [
    H1Config(style: h(30)),
    H2Config(style: h(25)),
    H3Config(style: h(21)),
    H4Config(style: h(18)),
    H5Config(style: h(16)),
    H6Config(style: h(14)),
  ]);
}
