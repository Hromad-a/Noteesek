import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web: trigger a browser download via a temporary object URL + anchor click.
Future<void> deliverExport(Uint8List bytes, String fileName) async =>
    deliverBytes(bytes, fileName, 'application/zip');

/// Web: download [bytes] as [fileName] (the [mimeType] sets the blob type).
/// [subject] is unused on web (the OS share-sheet concept doesn't apply).
Future<void> deliverBytes(Uint8List bytes, String fileName, String mimeType,
    {String? subject}) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
