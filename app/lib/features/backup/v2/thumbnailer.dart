import 'dart:typed_data';

import 'package:image/image.dart' as im;

/// Generates a small JPEG thumbnail (~256px on the long edge, q≈70) for the
/// backup preview grid. Matches the [Thumbnailer] typedef in backup_v2.dart.
/// Returns null on non-decodable bytes — the writer then simply omits the thumb
/// (preview falls back to a placeholder), so this never fails an export.
Future<(Uint8List, String)?> makeThumbnail(Uint8List source, String mime) async {
  try {
    final decoded = im.decodeImage(source);
    if (decoded == null) return null;
    final wide = decoded.width >= decoded.height;
    final resized = im.copyResize(decoded,
        width: wide ? 256 : null, height: wide ? null : 256);
    return (Uint8List.fromList(im.encodeJpg(resized, quality: 70)), 'jpg');
  } catch (_) {
    return null;
  }
}
