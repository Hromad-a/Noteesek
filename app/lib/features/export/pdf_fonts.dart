import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

/// Bundled Roboto fonts (latin + latin-ext) for PDF export, so note bodies
/// render real Unicode — Czech diacritics, bullets, etc. — instead of the
/// built-in WinAnsi fonts' missing glyphs. Loaded once and cached.
class PdfFonts {
  PdfFonts._(
    this.base,
    this.bold,
    this.italic,
    this.boldItalic,
    this.mono,
  );

  final pw.Font base;
  final pw.Font bold;
  final pw.Font italic;
  final pw.Font boldItalic;
  final pw.Font mono;

  /// A document theme that makes Roboto the default for all text (so emphasis,
  /// headings and lists inherit Unicode-capable fonts).
  pw.ThemeData get theme => pw.ThemeData.withFont(
        base: base,
        bold: bold,
        italic: italic,
        boldItalic: boldItalic,
      );

  static PdfFonts? _cache;

  static Future<PdfFonts> load() async {
    if (_cache != null) return _cache!;
    Future<pw.Font> f(String name) async =>
        pw.Font.ttf(await rootBundle.load('assets/fonts/$name'));
    _cache = PdfFonts._(
      await f('Roboto-Regular.ttf'),
      await f('Roboto-Bold.ttf'),
      await f('Roboto-Italic.ttf'),
      await f('Roboto-BoldItalic.ttf'),
      await f('RobotoMono-Regular.ttf'),
    );
    return _cache!;
  }
}
