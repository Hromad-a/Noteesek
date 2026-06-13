import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _downloads = MethodChannel('com.noteesek.app/downloads');

/// Android: hand [bytes] to native MediaStore so the file lands in the public
/// Downloads folder (no storage permission needed on API 29+). Other native
/// platforms (desktop) fall back to the OS Downloads/Documents directory.
Future<String> saveToDownloads(
    Uint8List bytes, String fileName, String mimeType) async {
  if (Platform.isAndroid) {
    final where = await _downloads.invokeMethod<String>('saveToDownloads', {
      'fileName': fileName,
      'bytes': bytes,
      'mimeType': mimeType,
    });
    return where ?? 'Downloads/$fileName';
  }
  final dir =
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  final file = File(p.join(dir.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
