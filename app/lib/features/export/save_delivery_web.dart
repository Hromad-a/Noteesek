import 'dart:typed_data';

import 'export_delivery.dart';

/// Web has no device filesystem: fall back to the normal browser download,
/// which already lands the file in the user's Downloads folder.
Future<String> saveToDownloads(
        Uint8List bytes, String fileName, String mimeType) async {
  await deliverBytes(bytes, fileName, mimeType);
  return 'your downloads folder';
}
