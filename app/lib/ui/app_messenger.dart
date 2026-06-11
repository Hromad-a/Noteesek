import 'package:flutter/material.dart';

/// App-wide [ScaffoldMessenger] key, wired into the root [MaterialApp]. Lets
/// non-widget layers (the remote repository, sync) surface a SnackBar without
/// needing a BuildContext.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Shows [message] as a SnackBar, replacing any current one so transient
/// failures (e.g. a burst of failed writes while offline) don't stack up.
///
/// Uses [clearSnackBars] (not [hideCurrentSnackBar]) so the swap is atomic: it
/// drops the current snackbar AND anything queued immediately, instead of
/// animating the old one out and queueing the new one — which, when several
/// calls interleave, can leave a snackbar stuck on screen past its duration.
void showAppSnackBar(String message) {
  scaffoldMessengerKey.currentState
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Shows [message] with an "Undo" action that runs [onUndo]. Uses the app-wide
/// messenger so it survives the screen that triggered it being popped (e.g. the
/// note editor closing after a delete).
void showUndoSnackBar({required String message, required VoidCallback onUndo}) {
  scaffoldMessengerKey.currentState
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 5),
      // A SnackBar with an action defaults to persist=true (Flutter 3.44+), so
      // without this it never times out and only a manual swipe dismisses it.
      persist: false,
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
    ));
}
