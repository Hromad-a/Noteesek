import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:noteesek/features/export/markdown_pdf.dart';

void main() {
  group('markdownToPdfWidgets', () {
    test('produces widgets for a representative document (no raw syntax)',
        () async {
      const src = '''
# Title

Some **bold** and *italic* and `code` and ~~struck~~ text with a [link](http://x).

## Subheading

- one
- two
  - nested
1. first
2. second

> a quote

```
code block
```

---
''';
      final widgets = markdownToPdfWidgets(src);
      expect(widgets, isNotEmpty);

      // The whole thing must lay out inside a real PDF without throwing.
      final doc = pw.Document();
      doc.addPage(pw.MultiPage(build: (_) => widgets));
      final bytes = await doc.save();
      expect(bytes.lengthInBytes, greaterThan(0));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('empty / whitespace source yields no widgets', () {
      expect(markdownToPdfWidgets(''), isEmpty);
      expect(markdownToPdfWidgets('   \n  '), isEmpty);
    });
  });
}
