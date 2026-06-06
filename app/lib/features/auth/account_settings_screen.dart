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

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: ref.read(serverUrlProvider));
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Server URL saved')));
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
                  onPressed: _pwBusy ? null : _changePassword,
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
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://localhost:8090',
              prefixIcon: Icon(Icons.dns_outlined),
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
