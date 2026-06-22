import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import 'app_lock.dart';

/// Full-screen unlock gate shown when the app is locked. Offers biometric
/// unlock (if enabled/available) and a PIN fallback.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _pinCtrl = TextEditingController();
  final _auth = LocalAuthentication();
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(appLockProvider).biometric) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
    }
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric() async {
    if (_checking) return;
    final reason = context.l10n.unlockNoteesek; // capture before awaits
    setState(() => _checking = true);
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return;
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      if (ok) ref.read(appLockProvider.notifier).unlock();
    } catch (_) {
      // Biometric unavailable/failed — fall back to the PIN.
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _submitPin() async {
    final ok = await ref.read(appLockProvider.notifier).verifyPin(_pinCtrl.text);
    if (!mounted) return;
    if (ok) {
      ref.read(appLockProvider.notifier).unlock();
    } else {
      setState(() => _error = 'Incorrect PIN');
      _pinCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final biometric = ref.watch(appLockProvider).biometric;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 16),
                Text(context.l10n.appLocked,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 24),
                TextField(
                  controller: _pinCtrl,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    labelText: context.l10n.pinLabel,
                    border: const OutlineInputBorder(),
                    errorText: _error,
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submitPin(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _submitPin,
                  child: Text(context.l10n.unlock),
                ),
                if (biometric) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _checking ? null : _tryBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(context.l10n.useBiometrics),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
