import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../providers.dart';

/// Completes a password reset: the user supplies the token from the reset email
/// (prefilled on web when arriving via the emailed `?reset=…` link) and a new
/// password. Calls `users.confirmPasswordReset` — no auth required.
///
/// On web this is shown by the app shell ahead of the login gate when a reset
/// token is present in the URL; on mobile it's pushed from the "Forgot
/// password?" flow on the login screen.
class PasswordResetScreen extends ConsumerStatefulWidget {
  const PasswordResetScreen({super.key, this.initialToken});

  /// Reset token prefilled from the email link (web). Null when the user must
  /// paste the code manually (mobile).
  final String? initialToken;

  @override
  ConsumerState<PasswordResetScreen> createState() =>
      _PasswordResetScreenState();
}

class _PasswordResetScreenState extends ConsumerState<PasswordResetScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _tokenCtrl;
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tokenCtrl = TextEditingController(text: widget.initialToken ?? '');
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  String _humanizeError(AppLocalizations l10n, ClientException e) {
    final msg = e.response['message'] as String?;
    if (msg != null && msg.isNotEmpty) return msg;
    if (e.statusCode == 0) return l10n.cannotReachServerCheckUrl;
    return l10n.requestFailed(e.statusCode);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = context.l10n; // capture before awaits
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(pocketBaseProvider).collection('users').confirmPasswordReset(
            _tokenCtrl.text.trim(),
            _newCtrl.text,
            _confirmCtrl.text,
          );
      if (!mounted) return;
      setState(() => _done = true);
    } on ClientException catch (e) {
      setState(() => _error = _humanizeError(l10n, e));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Leave the reset screen: clear the captured web token (so the app falls
  /// through to the login gate) and pop if we were pushed (mobile).
  void _backToSignIn() {
    ref.read(pendingResetTokenProvider.notifier).clear();
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.resetPasswordTitle),
        leading: BackButton(onPressed: _backToSignIn),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _done ? _success(context) : _form(context),
          ),
        ),
      ),
    );
  }

  Widget _success(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_outline,
            size: 48, color: Colors.green.shade600),
        const SizedBox(height: 16),
        Text(
          context.l10n.passwordChangedHeading,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.canNowSignIn,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _backToSignIn,
          child: Text(context.l10n.backToSignIn),
        ),
      ],
    );
  }

  Widget _form(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.chooseNewPassword,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.enterCodeAndPassword,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _tokenCtrl,
            decoration: InputDecoration(
              labelText: context.l10n.resetCode,
              prefixIcon: Icon(Icons.vpn_key_outlined),
            ),
            autocorrect: false,
            validator: (v) => (v != null && v.trim().isNotEmpty)
                ? null
                : context.l10n.pasteCodeFromEmail,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _newCtrl,
            decoration: InputDecoration(
              labelText: context.l10n.newPassword,
              prefixIcon: Icon(Icons.lock_reset_outlined),
            ),
            obscureText: true,
            validator: (v) =>
                (v != null && v.length >= 8) ? null : context.l10n.atLeast8Chars,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _confirmCtrl,
            decoration: InputDecoration(
              labelText: context.l10n.confirmNewPassword,
              prefixIcon: Icon(Icons.lock_reset_outlined),
            ),
            obscureText: true,
            onFieldSubmitted: (_) => _submit(),
            validator: (v) =>
                v == _newCtrl.text ? null : context.l10n.passwordsDoNotMatch,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.l10n.setNewPassword),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _backToSignIn,
            child: Text(context.l10n.backToSignIn),
          ),
        ],
      ),
    );
  }
}
