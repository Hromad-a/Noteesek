import 'dart:typed_data';

export 'save_delivery_stub.dart'
    if (dart.library.io) 'save_delivery_io.dart'
    if (dart.library.js_interop) 'save_delivery_web.dart';

/// Saves [bytes] to the device under [fileName] (into the public Downloads
/// folder on Android) without going through the OS share sheet, and returns a
/// human-readable location to show the user. Implemented per-platform via the
/// conditional export above.
typedef SaveToDownloads = Future<String> Function(
    Uint8List bytes, String fileName, String mimeType);
