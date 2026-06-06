import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../config/app_config.dart';
import '../../providers.dart';

/// Account settings for a connected user: change password, change the server
/// URL, and sign out. Reached from the drawer (web, or mobile while connected).
class AccountSettingsScreen extends ConsumerStatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  ConsumerState<AccountSettingsScreen> createState() =>
      _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends ConsumerState<AccountSettingsScreen> {
  final _pwFormKey = GlobalKey<FormState>();
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  late final TextEditingController _serverCtrl;

  bool _pwBusy = false;
  String? _pwError;

  bool _serverBusy = false;

  /// Reachability of the server we'd talk to. Gates the password change: a
  /// password change can't succeed (or be confirmed) while the server is down.
  _Conn _conn = _Conn.unknown;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: ref.read(serverUrlProvider));
    // Probe the currently-active server so password changes are gated correctly.
    _testConnection(ref.read(pocketBaseProvider).baseURL, silent: true);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Pings `<url>/api/health`. Updates [_conn]; when not [silent], also reports
  /// the result via a snackbar (used by the manual "Test connection" button).
  Future<void> _testConnection(String url, {required bool silent}) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (trimmed.isEmpty || uri == null || !uri.isAbsolute) {
      setState(() => _conn = _Conn.unreachable);
      if (!silent) _snack('Enter a valid URL');
      return;
    }
    setState(() => _conn = _Conn.checking);
    try {
      await PocketBase(trimmed).health.check();
      if (!mounted) return;
      setState(() => _conn = _Conn.ok);
      if (!silent) _snack('Server is reachable');
    } catch (_) {
      if (!mounted) return;
      setState(() => _conn = _Conn.unreachable);
      if (!silent) _snack('Cannot reach the server');
    }
  }

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  String _humanizeError(ClientException e) {
    final msg = e.response['message'] as String?;
    if (msg != null && msg.isNotEmpty) return msg;
    if (e.statusCode == 0) return 'Cannot reach the server. Check the URL.';
    return 'Request failed (${e.statusCode}).';
  }

  Future<void> _changePassword() async {
    if (!_pwFormKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _pwBusy = true;
      _pwError = null;
    });

    final pb = ref.read(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';
    final newPassword = _newCtrl.text;

    try {
      await pb.collection('users').update(pb.authStore.record!.id, body: {
        'oldPassword': _currentCtrl.text,
        'password': newPassword,
        'passwordConfirm': _confirmCtrl.text,
      });
      // Changing the password invalidates the current token; re-authenticate
      // so the user stays signed in.
      await pb.collection('users').authWithPassword(email, newPassword);

      if (!mounted) return;
      _currentCtrl.clear();
      _newCtrl.clear();
      _confirmCtrl.clear();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Password changed')));
    } on ClientException catch (e) {
      setState(() => _pwError = _humanizeError(e));
    } catch (e) {
      setState(() => _pwError = e.toString());
    } finally {
      if (mounted) setState(() => _pwBusy = false);
    }
  }

  Future<void> _saveServerUrl() async {
    final url = _serverCtrl.text.trim();
    final uri = Uri.tryParse(url);
    if (url.isEmpty || uri == null || !uri.isAbsolute) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Enter a valid URL')));
      return;
    }
    setState(() => _serverBusy = true);
    await ref.read(serverUrlProvider.notifier).set(url);
    if (!mounted) return;
    setState(() => _serverBusy = false);
    FocusScope.of(context).unfocus();
    _snack('Server URL saved');
    // Re-probe the now-active server so password gating reflects the new URL.
    _testConnection(url, silent: true);
  }

  Future<void> _signOut() async {
    final navigator = Navigator.of(context);
    ref.read(pocketBaseProvider).authStore.clear();
    if (!kIsWeb) {
      // Mobile: drop back to local-only ownership; notes stay on the device.
      await ref.read(activeOwnerProvider.notifier).set(AppConfig.localOwner);
    }
    // Web: the auth gate rebuilds to the login screen reactively. Mobile: pop
    // back to the notes screen.
    if (navigator.canPop()) navigator.pop();
  }

  /// The status icon shown in the server URL field's "Test connection" button.
  Widget _connIcon(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (_conn) {
      case _Conn.checking:
        return const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case _Conn.ok:
        return Icon(Icons.check_circle, color: Colors.green.shade600);
      case _Conn.unreachable:
        return Icon(Icons.error_outline, color: scheme.error);
      case _Conn.unknown:
        return const Icon(Icons.wifi_tethering);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pb = ref.watch(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Account settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Account'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(email.isEmpty ? 'Signed in' : email),
            subtitle: const Text('Signed in'),
          ),
          const SizedBox(height: 24),

          const _SectionHeader('Change password'),
          Form(
            key: _pwFormKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _currentCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Current password',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  obscureText: true,
                  validator: (v) => (v != null && v.isNotEmpty)
                      ? null
                      : 'Enter your current password',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _newCtrl,
                  decoration: const InputDecoration(
                    labelText: 'New password',
                    prefixIcon: Icon(Icons.lock_reset_outlined),
                  ),
                  obscureText: true,
                  validator: (v) =>
                      (v != null && v.length >= 8) ? null : 'At least 8 characters',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirmCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                    prefixIcon: Icon(Icons.lock_reset_outlined),
                  ),
                  obscureText: true,
                  onFieldSubmitted: (_) => _changePassword(),
                  validator: (v) =>
                      v == _newCtrl.text ? null : 'Passwords do not match',
                ),
                if (_conn == _Conn.unreachable) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.cloud_off,
                          size: 18,
                          color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Server not responding — you can't change your "
                          'password right now.',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_pwError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _pwError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: (_pwBusy || _conn != _Conn.ok)
                      ? null
                      : _changePassword,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: _pwBusy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Change password'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const _SectionHeader('Server'),
          TextField(
            controller: _serverCtrl,
            decoration: InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://localhost:8090',
              prefixIcon: const Icon(Icons.dns_outlined),
              suffixIcon: IconButton(
                tooltip: 'Test connection',
                onPressed: _conn == _Conn.checking
                    ? null
                    : () => _testConnection(_serverCtrl.text, silent: false),
                icon: _connIcon(context),
              ),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) => _saveServerUrl(),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _serverBusy ? null : _saveServerUrl,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _serverBusy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save server URL'),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout,
                color: Theme.of(context).colorScheme.error),
            title: Text(
              'Sign out',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: Text(kIsWeb
                ? 'Sign out of this account'
                : 'Stop syncing; notes stay on this device'),
            onTap: _signOut,
          ),
        ],
      ),
    );
  }
}

/// Server reachability state used to gate password changes and drive the
/// "Test connection" status icon.
enum _Conn { unknown, checking, ok, unreachable }

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
