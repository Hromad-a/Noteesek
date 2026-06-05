import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/auth/login_screen.dart';
import 'features/notes/notes_screen.dart';
import 'providers.dart';

class NoteesekApp extends ConsumerWidget {
  const NoteesekApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(isAuthenticatedProvider);

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
      home: loggedIn ? const NotesScreen() : const LoginScreen(),
    );
  }
}
