import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../config/app_config.dart';
import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import 'password_reset_screen.dart';
import 'reconciliation_screen.dart';

/// Connect to a self-hosted PocketBase server to enable sync (login or
/// register). The server URL is editable and persisted. On success, existing
/// local notes are claimed by the account and an initial sync runs.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _serverCtrl;
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _registerMode = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: ref.read(serverUrlProvider));
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = context.l10n; // capture before awaits
    setState(() {
      _busy = true;
      _error = null;
    });

    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    try {
      // Apply (and persist) the server URL first so the client points at it.
      await ref.read(serverUrlProvider.notifier).set(_serverCtrl.text.trim());
      final pb = ref.read(pocketBaseProvider);

      if (_registerMode) {
        await pb.collection('users').create(body: {
          'email': email,
          'password': password,
          'passwordConfirm': password,
        });
      }
      await pb.collection('users').authWithPassword(email, password);

      // Credentials worked — let the OS/password manager offer to save them.
      TextInput.finishAutofillContext();

      final userId = pb.authStore.record!.id;
      await ref.read(activeOwnerProvider.notifier).set(userId);
      final repo = ref.read(notesRepositoryProvider);

      // If the device holds *another account's* data, we can't merge across
      // accounts on a shared server — make the user wipe this device and load
      // the account fresh before the first sync. Offline `local` data isn't
      // foreign: it's simply claimed into the account below.
      if (!kIsWeb && await repo.hasForeignAccountData(userId)) {
        if (!mounted) return;
        final proceeded = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => ReconciliationScreen(userId: userId),
          ),
        );
        if (proceeded != true) {
          // Cancelled → undo the sign-in; the user stays on this screen.
          pb.authStore.clear();
          await ref
              .read(activeOwnerProvider.notifier)
              .set(AppConfig.localOwner);
          return;
        }
        // The screen already wiped + pulled the account.
      } else {
        await repo.claimLocalNotes(userId);
        if (!kIsWeb) {
          unawaited(ref.read(syncControllerProvider.notifier).syncNow());
        }
      }

      // Mobile: this screen was pushed → pop back. Web: it's the gate, so the
      // app rebuilds into the notes screen reactively once authenticated.
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
      return;
    } on ClientException catch (e) {
      setState(() => _error = _humanizeError(l10n, e));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanizeError(AppLocalizations l10n, ClientException e) {
    final msg = e.response['message'] as String?;
    if (msg != null && msg.isNotEmpty) return msg;
    if (e.statusCode == 0) return l10n.cannotReachServerCheckUrl;
    return l10n.requestFailed(e.statusCode);
  }

  /// Sends a password-reset email, then opens the confirm screen so the user can
  /// enter the emailed code and a new password. Requires a reachable server URL.
  Future<void> _forgotPassword() async {
    final l10n = context.l10n; // capture before awaits
    if ((_serverCtrl.text.trim().isEmpty) ||
        !(Uri.tryParse(_serverCtrl.text.trim())?.isAbsolute ?? false)) {
      setState(() => _error = l10n.enterServerUrlFirst);
      return;
    }

    final emailCtrl = TextEditingController(text: _emailCtrl.text.trim());
    final formKey = GlobalKey<FormState>();
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) {
        void submit() {
          if (formKey.currentState!.validate()) {
            Navigator.pop(ctx, emailCtrl.text.trim());
          }
        }

        return AlertDialog(
          title: Text(context.l10n.resetPasswordTitle),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.forgotPasswordEmailPrompt),
                const SizedBox(height: 12),
                TextFormField(
                  controller: emailCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: context.l10n.emailLabel,
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) =>
                      (v?.contains('@') ?? false) ? null : context.l10n.enterYourEmail,
                  onFieldSubmitted: (_) => submit(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: submit,
              child: Text(context.l10n.sendResetEmail),
            ),
          ],
        );
      },
    );
    emailCtrl.dispose();
    if (email == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Point the client at the typed server first (mobile may not be connected).
      await ref.read(serverUrlProvider.notifier).set(_serverCtrl.text.trim());
      await ref
          .read(pocketBaseProvider)
          .collection('users')
          .requestPasswordReset(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(l10n.resetEmailSentBody),
        ));
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const PasswordResetScreen(),
      ));
    } on ClientException catch (e) {
      setState(() => _error = _humanizeError(l10n, e));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // On mobile this is pushed (a back arrow appears); on web it's the gate.
      appBar: AppBar(
        title: Text(kIsWeb ? 'Noteesek' : context.l10n.connectToServer),
        automaticallyImplyLeading: !kIsWeb,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _registerMode
                        ? context.l10n.createAccountToSync
                        : context.l10n.signInToSync,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    kIsWeb ? context.l10n.loginBlurbWeb : context.l10n.loginBlurbMobile,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _serverCtrl,
                    decoration: InputDecoration(
                      labelText: context.l10n.serverUrlLabel,
                      hintText: 'http://localhost:8090',
                      prefixIcon: Icon(Icons.dns_outlined),
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return context.l10n.serverUrlRequired;
                      final uri = Uri.tryParse(t);
                      if (uri == null || !uri.isAbsolute) {
                        return context.l10n.enterValidUrl;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _emailCtrl,
                    decoration: InputDecoration(
                      labelText: context.l10n.emailLabel,
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    // Lets password managers recognise the credential field.
                    autofillHints: const [
                      AutofillHints.username,
                      AutofillHints.email,
                    ],
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v?.contains('@') ?? false) ? null : context.l10n.enterYourEmail,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordCtrl,
                    decoration: InputDecoration(
                      labelText: context.l10n.passwordLabel,
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    obscureText: true,
                    // New-password hint in register mode prompts a save/generate
                    // offer; current-password hint when signing in.
                    autofillHints: [
                      _registerMode
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) => (v != null && v.length >= 8)
                        ? null
                        : context.l10n.atLeast8Chars,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_registerMode ? context.l10n.createAccount : context.l10n.signIn),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _registerMode = !_registerMode;
                              _error = null;
                            }),
                    child: Text(_registerMode
                        ? context.l10n.haveAccountSignIn
                        : context.l10n.newHereCreate),
                  ),
                  if (!_registerMode)
                    TextButton(
                      onPressed: _busy ? null : _forgotPassword,
                      child: Text(context.l10n.forgotPassword),
                    ),
                ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
