import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../config/app_config.dart';
import '../../data/notes_repository.dart';
import '../../l10n/l10n.dart';
import '../../data/version_check.dart';
import '../backup/backup_service.dart' as backup;
import '../backup/remote_backup_service.dart';
import '../backup/v2/backup_restore_screen.dart';
import '../backup/v2/backup_v2_import.dart';
import '../../ui/web_centered.dart';
import '../backup/snapshots_screen.dart';
import '../lock/app_lock.dart';
import 'login_screen.dart';
import '../../providers.dart';
import '../../sync/sync_controller.dart';
import '../export/export_delivery.dart';
import '../export/export_service.dart';
import '../export/save_delivery.dart';
import '../import/import_models.dart';
import '../import/keep_import.dart';
import '../import/markdown_import.dart';

/// App settings, organised into sections: Account (change password, sign out),
/// Server (connection URL), and Data & storage (wipe). Reached from the drawer:
/// always on mobile, and on web (which is always signed in).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _pwFormKey = GlobalKey<FormState>();
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _pwBusy = false;
  String? _pwError;

  bool _wipeBusy = false;

  /// Reachability of the server we'd talk to. Gates the password change: a
  /// password change can't succeed (or be confirmed) while the server is down.
  _Conn _conn = _Conn.unknown;

  @override
  void initState() {
    super.initState();
    // Probe the currently-active server so password changes are gated correctly.
    _testConnection(ref.read(pocketBaseProvider).baseURL, silent: true);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the connect / sign-in flow (the "Account" and "Server" rows act as
  /// shortcuts into it when signed out).
  void _connect() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const LoginScreen()));
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

  /// Revoke every other session (rotates the account's token key server-side)
  /// and keep this device signed in with the fresh token it returns.
  // ignore: unused_element  (kept for when the feature is re-enabled — see build)
  Future<void> _signOutEverywhere() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out of all devices?'),
        content: const Text(
            'Every other device signed into this account is signed out '
            'immediately. This device stays signed in.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Sign out others')),
        ],
      ),
    );
    if (confirmed != true) return;
    final pb = ref.read(pocketBaseProvider);
    try {
      final res = await pb.send('/api/noteesek/logout-everywhere',
          method: 'POST');
      final token = (res is Map ? res['token'] : null) as String?;
      if (token != null && token.isNotEmpty) {
        // Adopt the fresh token so this device isn't logged out too.
        pb.authStore.save(token, pb.authStore.record);
      }
      _snack('Signed out of all other devices');
    } on ClientException catch (e) {
      _snack(_humanizeError(e));
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _signOut() async {
    final navigator = Navigator.of(context);
    ref.read(pocketBaseProvider).authStore.clear();
    if (!kIsWeb) {
      // Mobile: future new notes are stamped 'local' again (we're signed out).
      // This does NOT touch existing notes/notebooks — only the owner used for
      // new rows. Existing rows keep their account ownership and stay visible
      // (the local grid isn't owner-scoped).
      await ref.read(activeOwnerProvider.notifier).set(AppConfig.localOwner);
    }
    // Web: the auth gate rebuilds to the login screen reactively. Mobile: pop
    // back to the notes screen.
    if (navigator.canPop()) navigator.pop();
  }

  // ---------------- Export ----------------

  /// Builds a Markdown zip of all active + archived notes and hands it to the
  /// platform (share sheet on mobile / download on web).
  Future<void> _exportNotes() async {
    _snack('Preparing export…');
    try {
      final bytes =
          await NoteExportService(ref.read(notesRepositoryProvider)).buildZip();
      if (!mounted) return;
      if (bytes == null) {
        _snack('No notes to export');
        return;
      }
      await deliverExport(bytes, exportFileName());
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    } catch (e) {
      if (mounted) _snack('Export failed: $e');
    }
  }

  // ---------------- Import ----------------

  /// Asks which source to import from, then picks a file and runs the matching
  /// parser. Writes into the repository (local DB on mobile / PocketBase on web).
  Future<void> _importNotes() async {
    final source = await showModalBottomSheet<_ImportSource>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown export or .md files'),
              subtitle: const Text('A Noteesek export .zip or a single .md'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(_ImportSource.markdown),
            ),
            ListTile(
              leading: const Icon(Icons.add_to_drive_outlined),
              title: const Text('Google Keep (Takeout)'),
              subtitle: const Text('The Keep .zip from Google Takeout'),
              onTap: () => Navigator.of(sheetContext).pop(_ImportSource.keep),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final group = XTypeGroup(
      label: source == _ImportSource.keep ? 'Takeout zip' : 'Markdown',
      extensions:
          source == _ImportSource.keep ? ['zip'] : ['md', 'markdown', 'zip'],
      // Map to MIME/UTI so the picker filters correctly on Android/iOS/macOS.
      mimeTypes: source == _ImportSource.keep
          ? const ['application/zip']
          : const ['text/markdown', 'text/plain', 'application/zip'],
    );
    final XFile? file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final bytes = await file.readAsBytes();

    final List<ParsedNote> notes;
    try {
      notes = switch (source) {
        _ImportSource.markdown => parseMarkdownImport(bytes, file.name),
        _ImportSource.keep => parseKeepTakeout(bytes),
      };
    } catch (e) {
      _snack('Could not read that file: $e');
      return;
    }
    if (notes.isEmpty) {
      _snack('Nothing to import');
      return;
    }
    if (!mounted) return;

    // Pack the parsed notes into an in-memory v2 package and open the shared
    // preview, so importing uses the same grouped/searchable picker as a backup
    // restore — into a chosen notebook, as copies (no Replace for an import).
    final pkg = await parsedNotesToBackupBytes(notes);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BackupRestoreScreen(
        bytes: pkg,
        sourceLabel: file.name,
        title: 'Import notes',
        copiesOnly: true,
      ),
    ));
  }


  // ---------------- Backup / restore ----------------
  // Mobile backs up the local drift DB; web backs up the account via the
  // PocketBase API. Both round-trip the same JSON layout.

  String _backupFileName() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'noteesek-backup-${d.year}${two(d.month)}${two(d.day)}.zip';
  }

  Future<Uint8List> _exportBackup() => kIsWeb
      ? RemoteBackupService(ref.read(pocketBaseProvider)).exportV2()
      : backup.BackupService(ref.read(databaseProvider)).exportV2();

  /// Auto-detect format: a zip (PK header) is v2; otherwise the legacy v1 JSON.
  Future<int> _importBackup(Uint8List bytes) {
    final isZip = bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    if (kIsWeb) {
      final svc = RemoteBackupService(ref.read(pocketBaseProvider));
      return isZip ? svc.importV2(bytes) : svc.import(bytes);
    }
    final svc = backup.BackupService(ref.read(databaseProvider));
    return isZip
        ? svc.importV2(bytes, ref.read(activeOwnerProvider))
        : svc.import(bytes);
  }

  Future<void> _backUp() async {
    _snack('Preparing backup…');
    try {
      final bytes = await _exportBackup();
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      // Save straight to the device (Downloads) rather than the share sheet.
      final where =
          await saveToDownloads(bytes, _backupFileName(), 'application/zip');
      if (mounted) _snack('Backup saved to $where');
    } catch (e) {
      if (mounted) _snack('Backup failed: $e');
    }
  }

  Future<void> _restore() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(
        label: 'Noteesek backup',
        extensions: ['zip', 'json'],
        mimeTypes: ['application/zip', 'application/json'],
      ),
    ]);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    // v2 (a zip) → open the preview/restore screen so the user can add selected
    // notes or replace everything. Legacy v1 (JSON) → direct restore.
    final isZip = bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    if (isZip) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BackupRestoreScreen(bytes: bytes, sourceLabel: file.name),
      ));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(kIsWeb
            ? 'Notes from the backup are added to your account; where ids '
                'match, the backup version wins. This cannot be undone.'
            : 'Notes from the backup are merged into this device; where ids '
                'match, the backup version wins. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;

    _snack('Restoring…');
    try {
      final n = await _importBackup(bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      _snack('Restored $n note${n == 1 ? '' : 's'}');
    } catch (e) {
      if (mounted) _snack('Restore failed: $e');
    }
  }

  // ---------------- Wipe data ----------------

  /// Opens the destructive "wipe data" flow: pick targets (this device and/or
  /// this account's notes on the server) and type-to-confirm before anything is
  /// deleted. [signedIn] enables the server target.
  Future<void> _showWipeDialog({required bool signedIn}) async {
    final canLocal = !kIsWeb; // no local DB on web
    final canServer = signedIn;
    // Default the most natural target: the device on mobile, the server on web.
    var wipeLocal = canLocal;
    var wipeServer = !canLocal && canServer;
    final confirmCtrl = TextEditingController();
    const phrase = 'WIPE';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final scheme = Theme.of(ctx).colorScheme;
          final typedOk = confirmCtrl.text.trim().toUpperCase() == phrase;
          final anySelected =
              (canLocal && wipeLocal) || (canServer && wipeServer);
          return AlertDialog(
            title: const Text('Wipe data'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(canLocal && canServer
                      ? 'This permanently deletes the selected data. It cannot '
                          'be undone.'
                      : canServer
                          ? 'This permanently deletes your notes on the server '
                              '(only your account — other users are unaffected). '
                              'It cannot be undone.'
                          : 'This permanently deletes all notes on this device. '
                              'It cannot be undone.'),
                  const SizedBox(height: 8),
                  // Only offer the per-target choice when both targets actually
                  // apply. On web there's no local DB; on local-only mobile
                  // there's no server — in those cases the single target is
                  // implied (described above), so no checkbox is shown.
                  if (canLocal && canServer) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: wipeLocal,
                      onChanged: (v) =>
                          setLocal(() => wipeLocal = v ?? false),
                      title: const Text('This device'),
                      subtitle: const Text('Local notes database'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: wipeServer,
                      onChanged: (v) =>
                          setLocal(() => wipeServer = v ?? false),
                      title: const Text('On the server'),
                      subtitle: const Text(
                          'Only your account — other users are unaffected'),
                    ),
                    if (anySelected) ...[
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: scheme.outline),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              (wipeLocal && wipeServer)
                                  ? "You'll stay signed in — both copies are "
                                      'erased, so nothing re-syncs.'
                                  : "You'll be signed out so the remaining copy "
                                      "can't sync back.",
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  Text('Type "$phrase" to confirm',
                      style: Theme.of(ctx).textTheme.bodySmall),
                  const SizedBox(height: 4),
                  TextField(
                    controller: confirmCtrl,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(hintText: phrase),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ),
                onPressed: (typedOk && anySelected)
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('Wipe'),
              ),
            ],
          );
        },
      ),
    );
    confirmCtrl.dispose();
    if (confirmed != true) return;
    await _performWipe(
      wipeLocal: canLocal && wipeLocal,
      wipeServer: canServer && wipeServer,
    );
  }

  Future<void> _performWipe({
    required bool wipeLocal,
    required bool wipeServer,
  }) async {
    setState(() => _wipeBusy = true);
    _snack('Wiping…');
    final pb = ref.read(pocketBaseProvider);
    try {
      // Server first: if the device wipe clears a still-connected mirror, a
      // following sync shouldn't re-pull records we're about to delete server-side.
      if (wipeServer) {
        await _wipeServerData(pb);
      }
      if (wipeLocal) {
        await ref.read(databaseProvider).wipeAllLocal();
      }
      // Sign out unless BOTH sides were wiped. A one-sided wipe leaves the other
      // copy populated, so staying connected would just re-sync it back (the
      // device back onto a wiped server, or the server back onto a wiped
      // device). Wiping both leaves nothing to re-sync, so the session can stay.
      final bothWiped = wipeLocal && wipeServer;
      if (!kIsWeb && pb.authStore.isValid && !bothWiped) {
        pb.authStore.clear();
        await ref.read(activeOwnerProvider.notifier).set(AppConfig.localOwner);
      }
      if (!mounted) return;
      _snack('Data wiped');
    } catch (e) {
      if (!mounted) return;
      _snack('Wipe failed: ${e is ClientException ? _humanizeError(e) : e}');
    } finally {
      if (mounted) setState(() => _wipeBusy = false);
    }
  }

  /// Hard-deletes every record owned by the signed-in account. The collections'
  /// list rules are owner-scoped, so `getFullList` returns only this user's
  /// records — other users are never touched. Children are swept before their
  /// parents so we don't depend on server-side cascade configuration.
  Future<void> _wipeServerData(PocketBase pb) async {
    Future<void> purge(String collection) async {
      final records = await pb.collection(collection).getFullList();
      for (final r in records) {
        await pb.collection(collection).delete(r.id);
      }
    }

    await purge('attachments');
    await purge('checklist_items');
    await purge('notes');
    await purge('labels');
    await purge('notebooks');
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
    // Rebuild on every auth change so signing in via the connect shortcuts (a
    // pushed LoginScreen) reflects immediately on return, without navigating
    // away and back.
    ref.watch(authChangesProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';
    // While signed in, the server is fixed to the one we authenticated against.
    // Repointing it would leave a stale session against a different server, so
    // the URL is read-only until the user signs out.
    final signedIn = pb.authStore.isValid;
    final versionMismatch =
        ref.watch(versionStatusProvider).value?.mismatch ?? false;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: WebCentered(
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Account'),
          if (signedIn)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(email.isEmpty ? 'Signed in' : email),
              subtitle: Text(versionMismatch
                  ? 'App and server versions differ — see About below'
                  : 'Signed in'),
              trailing: versionMismatch
                  ? Tooltip(
                      message: 'App and server versions differ',
                      child: Icon(Icons.warning_amber_rounded,
                          color: Colors.orange.shade700),
                    )
                  : null,
            )
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text('Not connected'),
              subtitle: const Text(
                  'Connect a server to sync your notes across devices.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _connect,
            ),
          const SizedBox(height: 24),

          if (signedIn) ...[
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
                    validator: (v) => (v != null && v.length >= 8)
                        ? null
                        : 'At least 8 characters',
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
                        Icon(Icons.cloud_off, size: 18, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "Server not responding — you can't change your "
                            'password right now.',
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_pwError != null) ...[
                    const SizedBox(height: 12),
                    Text(_pwError!, style: TextStyle(color: scheme.error)),
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
          ],

          _SectionHeader(context.l10n.sectionAppearance),
          _ThemeModeSelector(),
          const _LanguageSelector(),
          Consumer(builder: (context, ref, _) {
            final on = ref.watch(markdownEnabledProvider);
            return SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.text_format),
              title: const Text('Markdown formatting'),
              subtitle: const Text(
                  'Render note text as Markdown and show a formatting toolbar'),
              value: on,
              onChanged: (v) =>
                  ref.read(markdownEnabledProvider.notifier).set(v),
            );
          }),
          const SizedBox(height: 24),

          // App lock is a device-local feature → mobile only.
          if (!kIsWeb) ...[
            const _SectionHeader('Security'),
            const _AppLockSection(),
            const SizedBox(height: 24),
          ],

          const _SectionHeader('Server'),
          // Display-only: the server URL is bound to the current session and can
          // only be changed by signing out and reconnecting (see the "Connect to
          // server" flow). Editing it here would strand the session on a server
          // that never issued its token.
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: Text(pb.baseURL),
            subtitle: Text(signedIn
                ? 'Sign out to connect to a different server.'
                : 'Tap to connect to a server and sign in.'),
            // When signed out, the row is a shortcut into the connect flow.
            onTap: signedIn ? null : _connect,
            // The live-availability check only makes sense for the server we're
            // actually signed in to — otherwise its green tick reads as "already
            // connected". Signed out, show the plain connect chevron instead.
            trailing: signedIn
                ? IconButton(
                    tooltip: 'Test connection',
                    onPressed: _conn == _Conn.checking
                        ? null
                        : () => _testConnection(pb.baseURL, silent: false),
                    icon: _connIcon(context),
                  )
                : const Icon(Icons.chevron_right),
          ),
          // Version history lives with the server config; shown even when not
          // connected (greyed out) so it's discoverable — it lights up once you
          // sign in to a server.
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: signedIn,
            leading: const Icon(Icons.history),
            title: const Text('Version history'),
            subtitle: Text(signedIn
                ? 'Automatic restore points'
                : 'Sign in to a server to use'),
            onTap: signedIn
                ? () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SnapshotsScreen(),
                    ))
                : null,
          ),
          // Sync status lives with the server too (mobile only — web is realtime).
          if (!kIsWeb && signedIn) _SyncStatusTile(),
          const SizedBox(height: 24),

          const _SectionHeader('Export'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.text_snippet_outlined),
            title: const Text('Markdown'),
            subtitle: const Text('Readable files for other apps'),
            onTap: _exportNotes,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Backup file'),
            subtitle: const Text('An exact copy you can restore later'),
            onTap: _backUp,
          ),
          const SizedBox(height: 16),

          const _SectionHeader('Import'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Notes'),
            subtitle: const Text('Markdown or Google Keep · adds copies'),
            onTap: _importNotes,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restore_outlined),
            title: const Text('Backup file'),
            subtitle: const Text('Restore everything, or merge selected'),
            onTap: _restore,
          ),
          const SizedBox(height: 16),

          const _SectionHeader('Danger zone'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _wipeBusy
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: Text('Wipe data', style: TextStyle(color: scheme.error)),
            subtitle: Text(kIsWeb
                ? 'Permanently delete your notes on the server'
                : signedIn
                    ? 'Permanently delete notes on this device and/or the server'
                    : 'Permanently delete all notes on this device'),
            onTap: _wipeBusy ? null : () => _showWipeDialog(signedIn: signedIn),
          ),
          const SizedBox(height: 24),

          const _SectionHeader('About'),
          _AboutSection(signedIn: signedIn),

          if (signedIn) ...[
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 8),
            // "Sign out of all devices" is hidden for now — it didn't reliably
            // invalidate web sessions. Re-enable by restoring the ListTile below
            // (and remove the ignore on _signOutEverywhere) once that's fixed.
            // ListTile(
            //   contentPadding: EdgeInsets.zero,
            //   leading: const Icon(Icons.devices_outlined),
            //   title: const Text('Sign out of all devices'),
            //   subtitle: const Text(
            //       'Invalidate every other login; this device stays signed in'),
            //   onTap: _signOutEverywhere,
            // ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout, color: scheme.error),
              title: Text('Sign out', style: TextStyle(color: scheme.error)),
              subtitle: Text(kIsWeb
                  ? 'Sign out of this account'
                  : 'Stop syncing; notes stay on this device'),
              onTap: _signOut,
            ),
          ],
        ],
      )),
    );
  }
}

/// Which external format an import reads from.
enum _ImportSource { markdown, keep }

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

/// Mobile-only sync status row: a simple state icon (synced / syncing /
/// offline) plus the last-synced time, tappable to sync now.
class _SyncStatusTile extends ConsumerWidget {
  String _ago(DateTime? t) {
    if (t == null) return 'Not synced yet';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 10) return 'Last synced just now';
    if (d.inMinutes < 1) return 'Last synced ${d.inSeconds}s ago';
    if (d.inMinutes < 60) return 'Last synced ${d.inMinutes} min ago';
    if (d.inHours < 24) return 'Last synced ${d.inHours} h ago';
    return 'Last synced ${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final hasPending = ref.watch(hasPendingChangesProvider).value ?? false;
    final scheme = Theme.of(context).colorScheme;

    final (Widget leading, String title, String subtitle) = switch (sync) {
      _ when sync.syncing => (
          const SizedBox(
            height: 24,
            width: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          'Syncing…',
          _ago(sync.lastSync),
        ),
      _ when !sync.reachable => (
          Icon(Icons.cloud_off, color: scheme.error),
          'Offline',
          'Server not responding',
        ),
      _ when hasPending => (
          const Icon(Icons.cloud_upload_outlined),
          'Changes not synced',
          'Tap Sync now to push them',
        ),
      _ => (
          const Icon(Icons.cloud_done_outlined),
          'Synced',
          _ago(sync.lastSync),
        ),
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: sync.syncing
          ? null
          : TextButton.icon(
              onPressed: () =>
                  ref.read(syncControllerProvider.notifier).syncNow(manual: true),
              icon: const Icon(Icons.sync, size: 18),
              label: const Text('Sync now'),
            ),
    );
  }
}

/// A parsed app/server version (e.g. version "1.2.0", build "3").
class _VersionInfo {
  const _VersionInfo(this.version, this.build);

  final String version;
  final String build;

  String get display => build.isEmpty ? version : '$version ($build)';
}

/// App and server version rows. On mobile it shows the installed app version
/// and — when connected — the server's version, warning if the two semantic
/// versions differ (build number ignored). On web there's only one build, so it
/// shows just the server version.
class _AboutSection extends ConsumerStatefulWidget {
  const _AboutSection({required this.signedIn});

  final bool signedIn;

  @override
  ConsumerState<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<_AboutSection> {
  _VersionInfo? _app;
  _VersionInfo? _server;
  bool _serverLoading = false;
  bool _serverFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!kIsWeb) {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _app = _VersionInfo(info.version, info.buildNumber));
      }
    }
    // Fetch the server version when there's a server to ask: always on web
    // (its own origin), and on mobile only once connected.
    if (kIsWeb || widget.signedIn) {
      await _loadServer();
    }
  }

  Future<void> _loadServer() async {
    setState(() {
      _serverLoading = true;
      _serverFailed = false;
    });
    final baseURL = ref.read(pocketBaseProvider).baseURL;
    final info = await _fetchServerVersion(baseURL);
    if (!mounted) return;
    setState(() {
      _server = info;
      _serverFailed = info == null;
      _serverLoading = false;
    });
  }

  /// GETs `<baseURL>/version.json` (the manifest Flutter emits into the web
  /// build the server serves). Returns null if unreachable or malformed.
  Future<_VersionInfo?> _fetchServerVersion(String baseURL) async {
    final base = baseURL.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/version.json');
    if (uri == null) return null;
    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final v = (json['version'] ?? '').toString();
      final b = (json['build_number'] ?? '').toString();
      if (v.isEmpty) return null;
      return _VersionInfo(v, b);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mismatch = _app != null &&
        _server != null &&
        _app!.version != _server!.version;

    Widget serverTrailing() {
      if (_serverLoading) {
        return const SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      }
      if (mismatch) {
        return Tooltip(
          message: 'App and server versions differ',
          child: Icon(Icons.warning_amber_rounded,
              color: Colors.orange.shade700),
        );
      }
      return const SizedBox.shrink();
    }

    String serverSubtitle() {
      if (_serverLoading) return 'Checking…';
      if (_serverFailed || _server == null) return 'Unavailable';
      return _server!.display;
    }

    return Column(
      children: [
        // App version: mobile only (on web the app *is* the server build).
        if (!kIsWeb)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.smartphone_outlined),
            title: const Text('App version'),
            subtitle: Text(_app?.display ?? '…'),
          ),
        // Server version: on web always; on mobile only when connected.
        if (kIsWeb || widget.signedIn)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server version'),
            subtitle: Text(serverSubtitle()),
            trailing: serverTrailing(),
          ),
        if (mismatch)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This app (${_app!.version}) and the server '
                    '(${_server!.version}) are different versions. Some '
                    'features may not work until both are updated.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Light / Dark / System theme picker, bound to [themeModeProvider].
class _ThemeModeSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SegmentedButton<ThemeMode>(
        segments: [
          ButtonSegment(
            value: ThemeMode.system,
            label: Text(context.l10n.themeSystem),
            icon: const Icon(Icons.brightness_auto_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            label: Text(context.l10n.themeLight),
            icon: const Icon(Icons.light_mode_outlined),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            label: Text(context.l10n.themeDark),
            icon: const Icon(Icons.dark_mode_outlined),
          ),
        ],
        selected: {mode},
        showSelectedIcon: false,
        onSelectionChanged: (s) =>
            ref.read(themeModeProvider.notifier).set(s.first),
      ),
    );
  }
}

/// Language picker bound to [localeProvider]. `null` = follow the device.
/// Opens a simple radio dialog with System default / English / Čeština.
class _LanguageSelector extends ConsumerWidget {
  const _LanguageSelector();

  String _label(BuildContext context, Locale? locale) => switch (locale?.languageCode) {
        'en' => context.l10n.languageEnglish,
        'cs' => context.l10n.languageCzech,
        _ => context.l10n.languageSystemDefault,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(localeProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.translate_outlined),
      title: Text(context.l10n.languageLabel),
      subtitle: Text(_label(context, current)),
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(context.l10n.languageLabel),
          // Set straight from the radio (then close) so a dismiss changes
          // nothing — a returned-value approach can't tell "System default"
          // (null) apart from a barrier-dismiss (also null).
          children: [
            RadioGroup<String?>(
              groupValue: current?.languageCode,
              onChanged: (code) {
                ref
                    .read(localeProvider.notifier)
                    .set(code == null ? null : Locale(code));
                Navigator.of(ctx).pop();
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in <Locale?>[
                    null,
                    const Locale('en'),
                    const Locale('cs')
                  ])
                    RadioListTile<String?>(
                      value: option?.languageCode,
                      title: Text(_label(ctx, option)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App-lock controls: enable/disable (with a PIN), biometric toggle, change PIN.
class _AppLockSection extends ConsumerWidget {
  const _AppLockSection();

  /// Prompts for a new PIN twice (entry + confirm). Returns the PIN, or null if
  /// cancelled / mismatched.
  static Future<String?> _promptNewPin(BuildContext context) {
    final pin = TextEditingController();
    final confirm = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Set a PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pin,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'PIN'),
                ),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration:
                      InputDecoration(labelText: 'Confirm PIN', errorText: error),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final p = pin.text;
                  if (p.length < 4) {
                    setLocal(() => error = 'Use at least 4 digits');
                  } else if (p != confirm.text) {
                    setLocal(() => error = "PINs don't match");
                  } else {
                    Navigator.of(ctx).pop(p);
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      pin.dispose();
      confirm.dispose();
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    final notifier = ref.read(appLockProvider.notifier);
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.lock_outline),
          title: const Text('App lock'),
          subtitle: const Text('Require a PIN or biometrics to open the app'),
          value: lock.enabled,
          onChanged: (on) async {
            if (on) {
              final pin = await _promptNewPin(context);
              if (pin != null) await notifier.enable(pin);
            } else {
              await notifier.disable();
            }
          },
        ),
        if (lock.enabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Unlock with biometrics'),
            value: lock.biometric,
            onChanged: notifier.setBiometric,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.password_outlined),
            title: const Text('Change PIN'),
            onTap: () async {
              final pin = await _promptNewPin(context);
              if (pin != null) await notifier.changePin(pin);
            },
          ),
        ],
      ],
    );
  }
}
