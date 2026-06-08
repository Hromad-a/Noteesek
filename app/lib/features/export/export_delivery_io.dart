import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Mobile/desktop: write the zip to a temp file and open the OS share sheet.
Future<void> deliverExport(Uint8List bytes, String fileName) async =>
    deliverBytes(bytes, fileName, 'application/zip', subject: 'Noteesek export');

/// Mobile/desktop: write [bytes] to a temp file under [fileName] and open the
/// OS share sheet, tagged with [mimeType].
Future<void> deliverBytes(Uint8List bytes, String fileName, String mimeType,
    {String? subject}) async {
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, fileName));
  await file.writeAsBytes(bytes, flush: true);
  await Share.shareXFiles(
    [XFile(file.path, mimeType: mimeType, name: fileName)],
    subject: subject,
  );
}
