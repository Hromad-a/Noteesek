import 'dart:typed_data';

export 'export_delivery_stub.dart'
    if (dart.library.io) 'export_delivery_io.dart'
    if (dart.library.js_interop) 'export_delivery_web.dart';

/// Hands the built export [bytes] to the user under [fileName]: the OS share
/// sheet on mobile, a browser download on web. Implemented per-platform via the
/// conditional export above.
typedef DeliverExport = Future<void> Function(
    Uint8List bytes, String fileName);
