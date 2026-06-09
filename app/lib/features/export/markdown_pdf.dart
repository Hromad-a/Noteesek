import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Renders a Markdown [source] string to a list of `pdf` widgets so notes export
/// to PDF *looking* like Markdown (headings, lists, emphasis, code, quotes, …)
/// instead of dumping the raw `#`/`*`/`-` syntax. Pure (no I/O); used by
/// `buildNotePdf`.
///
/// Covers the subset the in-app editor produces: headings, paragraphs,
/// bold/italic/inline-code/strikethrough, links (shown as their text),
/// bullet/ordered lists (nested), block quotes, fenced code blocks, and rules.
List<pw.Widget> markdownToPdfWidgets(String source, {pw.Font? mono}) {
  _mono = mono ?? pw.Font.courier();
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final nodes = document.parse(source.replaceAll('\r\n', '\n'));
  final widgets = <pw.Widget>[];
  for (final node in nodes) {
    final w = _block(node);
    if (w != null) widgets.add(w);
  }
  return widgets;
}

const _baseSize = 11.0;

/// Monospace font for code spans/blocks — the bundled Roboto Mono when the
/// caller provides it, else the built-in Courier (Latin-1 only).
pw.Font _mono = pw.Font.courier();

pw.Widget? _block(md.Node node, {double indent = 0}) {
  if (node is md.Text) {
    final text = node.text.trim();
    return text.isEmpty ? null : _para(pw.TextSpan(text: text));
  }
  if (node is! md.Element) return null;

  switch (node.tag) {
    case 'h1':
      return _heading(node, 22);
    case 'h2':
      return _heading(node, 18);
    case 'h3':
      return _heading(node, 15);
    case 'h4':
    case 'h5':
    case 'h6':
      return _heading(node, 13);
    case 'p':
      return _para(_inline(node.children));
    case 'hr':
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 8),
        child: pw.Divider(height: 1, color: PdfColors.grey400),
      );
    case 'blockquote':
      return pw.Container(
        margin: const pw.EdgeInsets.symmetric(vertical: 4),
        padding: const pw.EdgeInsets.only(left: 10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
              left: pw.BorderSide(color: PdfColors.grey400, width: 3)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: _children(node).whereType<pw.Widget>().toList(),
        ),
      );
    case 'pre':
      return pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.symmetric(vertical: 4),
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          color: PdfColors.grey100,
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Text(_codeText(node),
            style: pw.TextStyle(font: _mono, fontSize: _baseSize - 1)),
      );
    case 'ul':
      return _list(node, ordered: false, indent: indent);
    case 'ol':
      return _list(node, ordered: true, indent: indent);
    default:
      // Unknown block: fall back to its inline content as a paragraph.
      return _para(_inline(node.children));
  }
}

List<pw.Widget> _children(md.Element node) {
  final out = <pw.Widget>[];
  for (final c in node.children ?? const <md.Node>[]) {
    final w = _block(c);
    if (w != null) out.add(w);
  }
  return out;
}

pw.Widget _heading(md.Element node, double size) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 8, bottom: 2),
      child: pw.RichText(
        text: _inline(node.children,
            base: pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold)),
      ),
    );

pw.Widget _para(pw.InlineSpan span) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.RichText(text: span),
    );

pw.Widget _list(md.Element node, {required bool ordered, double indent = 0}) {
  final rows = <pw.Widget>[];
  var index = 1;
  for (final item in node.children ?? const <md.Node>[]) {
    if (item is! md.Element || item.tag != 'li') continue;
    final marker = ordered ? '$index.' : '•';
    index++;

    // An <li> mixes inline content with nested lists. Split the two so the
    // bullet sits beside the text and nested lists indent under it.
    final inlineNodes = <md.Node>[];
    final blockNodes = <md.Element>[];
    for (final c in item.children ?? const <md.Node>[]) {
      if (c is md.Element && (c.tag == 'ul' || c.tag == 'ol')) {
        blockNodes.add(c);
      } else {
        inlineNodes.add(c);
      }
    }

    rows.add(pw.Padding(
      padding: pw.EdgeInsets.only(left: indent, top: 1, bottom: 1),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: ordered ? 18 : 12,
            child: pw.Text(marker, style: const pw.TextStyle(fontSize: _baseSize)),
          ),
          pw.Expanded(child: pw.RichText(text: _inline(inlineNodes))),
        ],
      ),
    ));
    for (final nested in blockNodes) {
      final w = _block(nested, indent: indent + 14);
      if (w != null) rows.add(w);
    }
  }
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: rows);
}

String _codeText(md.Element pre) {
  // <pre><code>…</code></pre> — pull the raw text out.
  final code = (pre.children?.isNotEmpty ?? false) ? pre.children!.first : pre;
  if (code is md.Element) {
    return code.textContent.replaceAll(RegExp(r'\n$'), '');
  }
  return pre.textContent;
}

/// Builds a rich [pw.TextSpan] from inline Markdown nodes, threading bold /
/// italic / code / strikethrough styles down the tree.
pw.InlineSpan _inline(List<md.Node>? nodes, {pw.TextStyle? base}) {
  final style = base ?? const pw.TextStyle(fontSize: _baseSize);
  final children = <pw.InlineSpan>[];
  for (final n in nodes ?? const <md.Node>[]) {
    if (n is md.Text) {
      children.add(pw.TextSpan(text: _unescape(n.text)));
    } else if (n is md.Element) {
      final next = switch (n.tag) {
        'strong' => style.copyWith(fontWeight: pw.FontWeight.bold),
        'em' => style.copyWith(fontStyle: pw.FontStyle.italic),
        'del' => style.copyWith(decoration: pw.TextDecoration.lineThrough),
        'code' => style.copyWith(font: _mono, fontSize: _baseSize - 1),
        'a' => style.copyWith(
            color: PdfColors.blue700, decoration: pw.TextDecoration.underline),
        _ => style,
      };
      if (n.tag == 'br') {
        children.add(const pw.TextSpan(text: '\n'));
      } else if (n.tag == 'code' && (n.children?.isEmpty ?? true)) {
        children.add(pw.TextSpan(text: n.textContent, style: next));
      } else {
        children.add(_inline(n.children, base: next));
      }
    }
  }
  return pw.TextSpan(style: style, children: children);
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
