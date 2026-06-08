import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/auth/login_screen.dart';
import 'features/auth/password_reset_screen.dart';
import 'features/notes/notes_screen.dart';
import 'providers.dart';
import 'ui/app_messenger.dart';

class NoteesekApp extends ConsumerWidget {
  const NoteesekApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Web is an online, server-backed client → login required. Mobile is
    // local-first → opens straight to local notes.
    final Widget home;
    if (kIsWeb) {
      // A reset token in the launch URL (?reset=…) takes priority over the login
      // gate so users completing a password reset land on the confirm screen.
      final resetToken = ref.watch(pendingResetTokenProvider);
      if (resetToken != null) {
        home = PasswordResetScreen(initialToken: resetToken);
      } else {
        home = ref.watch(isAuthenticatedProvider)
            ? const NotesScreen()
            : const LoginScreen();
      }
    } else {
      home = const NotesScreen();
    }

    return MaterialApp(
      title: 'Noteesek',
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFCEB1E8),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFFCEB1E8),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: ref.watch(themeModeProvider),
      home: home,
    );
  }
}
