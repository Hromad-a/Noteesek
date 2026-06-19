import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:noteesek/features/notes/note_markdown_config.dart';

void main() {
  testWidgets('all six heading levels get distinct, descending sizes',
      (tester) async {
    late MarkdownConfig cfg;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        cfg = noteMarkdownConfig(context);
        return const SizedBox();
      }),
    ));

    final sizes = [cfg.h1, cfg.h2, cfg.h3, cfg.h4, cfg.h5, cfg.h6]
        .map((h) => h.style.fontSize!)
        .toList();

    // Regression: the package default flattens H4–H6 to 16px. Every level must
    // now be strictly smaller than the one above it.
    for (var i = 0; i < sizes.length - 1; i++) {
      expect(sizes[i], greaterThan(sizes[i + 1]),
          reason: 'h${i + 1} (${sizes[i]}) must be larger than '
              'h${i + 2} (${sizes[i + 1]})');
    }
    expect(sizes.toSet().length, 6, reason: 'all six sizes are distinct');
  });
}
