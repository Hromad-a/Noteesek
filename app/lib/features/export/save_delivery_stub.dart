import 'dart:typed_data';

/// Fallback used only if neither dart:io nor web is available.
Future<String> saveToDownloads(
    Uint8List bytes, String fileName, String mimeType) async {
  throw UnsupportedError('Saving is not supported on this platform');
}
