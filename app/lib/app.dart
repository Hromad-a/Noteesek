import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/auth/login_screen.dart';
import 'features/auth/password_reset_screen.dart';
import 'features/lock/app_lock.dart';
import 'features/lock/lock_screen.dart';
import 'features/notes/notes_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'providers.dart';
import 'ui/app_messenger.dart';

/// Lavender brand seed for the Material 3 color scheme (light + dark).
const Color _seed = Color(0xFFCEB1E8);

class NoteesekApp extends ConsumerStatefulWidget {
  const NoteesekApp({super.key});

  @override
  ConsumerState<NoteesekApp> createState() => _NoteesekAppState();
}

class _NoteesekAppState extends ConsumerState<NoteesekApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock when the app leaves the foreground so returning to it requires
    // an unlock. No-op when the lock is off.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ref.read(appLockProvider.notifier).lock();
    }
  }

  @override
  Widget build(BuildContext context) {
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

    // First-run intro (mobile) takes precedence over everything else.
    final lock = ref.watch(appLockProvider);
    final Widget gatedHome;
    if (!kIsWeb && !ref.watch(onboardingSeenProvider)) {
      gatedHome = const OnboardingScreen();
    } else if (!kIsWeb && lock.enabled && lock.locked) {
      // App lock: when on and locked, the unlock gate replaces everything.
      gatedHome = const LockScreen();
    } else {
      gatedHome = home;
    }

    return MaterialApp(
      title: 'Noteesek',
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // `vibrant` keeps the lavender hue but with more chroma than the default
        // `tonalSpot`, so light surfaces/containers carry more visible purple.
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6EEFB), // soft lavender canvas
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
        ),
        useMaterial3: true,
      ),
      themeMode: ref.watch(themeModeProvider),
      home: gatedHome,
    );
  }
}
