import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/ui/app_messenger.dart';

void main() {
  // Regression: in Flutter 3.44+ a SnackBar with an action defaults to
  // persist=true and never times out. The undo snackbar must still auto-dismiss.
  testWidgets('undo snackbar auto-dismisses after its duration', (tester) async {
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));

    showUndoSnackBar(message: 'Note moved to Trash', onUndo: () {});
    await tester.pumpAndSettle();
    expect(find.text('Note moved to Trash'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('Note moved to Trash'), findsNothing);
  });
}
