import 'package:flutter/material.dart';

/// App-wide [ScaffoldMessenger] key, wired into the root [MaterialApp]. Lets
/// non-widget layers (the remote repository, sync) surface a SnackBar without
/// needing a BuildContext.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Shows [message] as a SnackBar, replacing any current one so transient
/// failures (e.g. a burst of failed writes while offline) don't stack up.
void showAppSnackBar(String message) {
  scaffoldMessengerKey.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
