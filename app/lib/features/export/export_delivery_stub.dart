import 'dart:typed_data';

/// Fallback used only if neither dart:io nor web is available.
Future<void> deliverExport(Uint8List bytes, String fileName) async {
  throw UnsupportedError('Export is not supported on this platform');
}
