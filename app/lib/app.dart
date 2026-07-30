import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/l10n.dart';

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

// Light-theme lavender surface tints (hand-picked so the grid reads as gently
// purple). Cards sit a shade lighter than the canvas/chrome so they still pop.
const Color _lightCanvas = Color(0xFFF7F1FC); // scaffold + app bar (lightest)
const Color _lightChrome = Color(0xFFEFE5F9); // bottom bar + drawer
const Color _lightCard = Color(0xFFEADFF6); // default note card (soft lavender)

class NoteesekApp extends ConsumerStatefulWidget {
  const NoteesekApp({super.key});

  @override
  ConsumerState<NoteesekApp> createState() => _NoteesekAppState();
}

class _NoteesekAppState extends ConsumerState<NoteesekApp>
    with WidgetsBindingObserver {
  // Guards against stacking the "you've been signed out" dialog while one is
  // already up (build can run several times before it's dismissed).
  bool _sessionPromptShowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Probe the session once on launch: hit authRefresh so a token the server
    // has since rejected (password changed elsewhere / "sign out everywhere")
    // is caught right away — the auth-guard http client clears it on the 401 and
    // flags the session invalidated, driving the sign-in prompt below, instead
    // of the user meeting a silent, unsyncable screen. Fail-soft: a network
    // error leaves the existing token untouched. Runs on every platform (mobile
    // sync also refreshes, but this makes the prompt appear promptly on open).
    final pb = ref.read(pocketBaseProvider);
    if (pb.authStore.isValid) {
      pb.collection('users').authRefresh().then((_) {}, onError: (_) {});
    }
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

  /// Show the one-time "you've been signed out" prompt when the session was
  /// invalidated server-side. Scheduled post-frame so it can run from build; the
  /// root navigator key gives it a context even before any screen is mounted.
  void _promptSignedOut() {
    if (_sessionPromptShowing) return;
    _sessionPromptShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null || !mounted) {
        _sessionPromptShowing = false;
        return;
      }
      final l10n = ctx.l10n;
      await showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          title: Text(l10n.sessionExpiredTitle),
          content: Text(l10n.sessionExpiredBody),
          actions: [
            TextButton(
              onPressed: () {
                ref.read(sessionInvalidatedProvider.notifier).acknowledge();
                Navigator.of(dialogCtx).pop();
                // On web the login gate is already the home once auth cleared;
                // on mobile (local-first) push the connect/login screen.
                if (!kIsWeb) {
                  appNavigatorKey.currentState?.push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                }
              },
              child: Text(l10n.signIn),
            ),
          ],
        ),
      );
      _sessionPromptShowing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // A server-invalidated session (password changed / signed out everywhere)
    // surfaces a prompt to sign in again, on top of whatever screen is showing.
    if (ref.watch(sessionInvalidatedProvider)) _promptSignedOut();

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
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // `vibrant` keeps the lavender hue but with more chroma than the default
        // `tonalSpot`, so light surfaces/containers carry more visible purple.
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
          dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
        ),
        // A gently lavender light theme: a tinted canvas + matching chrome, with
        // cards a shade lighter so the grid reads as soft purple panels rather
        // than stark white. (Per-note colors still override the card colour.)
        scaffoldBackgroundColor: _lightCanvas,
        cardTheme: const CardThemeData(color: _lightCard),
        appBarTheme: const AppBarTheme(
          backgroundColor: _lightCanvas,
          scrolledUnderElevation: 0,
        ),
        bottomAppBarTheme: const BottomAppBarThemeData(color: _lightChrome),
        navigationDrawerTheme: const NavigationDrawerThemeData(
          backgroundColor: _lightChrome,
        ),
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
      // Language: an explicit override from the picker, else null = follow the
      // device language. Only en/cs are supported; anything else falls back to
      // the first supported locale (en).
      locale: ref.watch(localeProvider),
      supportedLocales: kSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: gatedHome,
    );
  }
}
