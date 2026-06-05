import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/auth/login_screen.dart';
import 'features/notes/notes_screen.dart';
import 'providers.dart';

class NoteesekApp extends ConsumerWidget {
  const NoteesekApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Web is an online, server-backed client → login required. Mobile is
    // local-first → opens straight to local notes.
    final Widget home;
    if (kIsWeb) {
      home = ref.watch(isAuthenticatedProvider)
          ? const NotesScreen()
          : const LoginScreen();
    } else {
      home = const NotesScreen();
    }

    return MaterialApp(
      title: 'Noteesek',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFFFC107),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFFFFC107),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: home,
    );
  }
}
