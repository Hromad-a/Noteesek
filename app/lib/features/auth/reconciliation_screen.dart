import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../sync/reconciliation_service.dart';
import '../../sync/sync_controller.dart';

/// Shown on mobile sign-in when the device holds data from *another account*
/// (see docs/sign-in-reconciliation.md). We don't merge across accounts on a
/// shared server, so the only safe choice is to wipe this device and load the
/// signed-in account fresh from the server. Pops `true` once the wipe+pull has
/// run, `false` if the user cancels (the caller then undoes the sign-in).
///
/// Offline `local` data never lands here — it's claimed into the account by the
/// normal sign-in path. To move notes between accounts, export and re-import.
class ReconciliationScreen extends ConsumerStatefulWidget {
  const ReconciliationScreen({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<ReconciliationScreen> createState() =>
      _ReconciliationScreenState();
}

class _ReconciliationScreenState extends ConsumerState<ReconciliationScreen> {
  ReconciliationService get _service => ReconciliationService(
        ref.read(databaseProvider),
        ref.read(pocketBaseProvider),
        ref.read(syncEngineProvider),
      );

  ReconcileSummary? _summary;
  Object? _inspectError;
  bool _running = false;

  /// Word the user must type to confirm the wipe.
  static const _confirmWord = 'REPLACE';
  final _confirmCtrl = TextEditingController();

  bool get _canContinue =>
      _confirmCtrl.text.trim().toUpperCase() == _confirmWord;

  @override
  void initState() {
    super.initState();
    _inspect();
  }

  @override
  void dispose() {
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _inspect() async {
    setState(() {
      _summary = null;
      _inspectError = null;
    });
    try {
      final s = await _service.inspect(widget.userId);
      if (mounted) setState(() => _summary = s);
    } catch (e) {
      if (mounted) setState(() => _inspectError = e);
    }
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      await _service.keepServerReplace();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // a choice (or Cancel) must be made; no silent back-out
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Switch account'),
          automaticallyImplyLeading: false,
        ),
        body: _inspectError != null
            ? _ErrorBody(error: _inspectError!, onRetry: _inspect)
            : _summary == null
                ? const Center(child: CircularProgressIndicator())
                : _buildBody(context, _summary!),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ReconcileSummary s) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'This device holds notes from another account.',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              "Notes can't be merged across accounts. To continue, this "
              "device's data will be replaced with the data from the account "
              'you just signed into.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _BackupWarning(),
            const SizedBox(height: 16),
            _SummaryCard(summary: s),
            const SizedBox(height: 24),
            _confirmGuard(context, s),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: (_running || !_canContinue) ? null : _run,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              child: const Text('Replace this device with the server'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed:
                  _running ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
        if (_running)
          ColoredBox(
            color: const Color(0x88000000),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Replacing…', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Type-to-confirm gate for the wipe.
  Widget _confirmGuard(BuildContext context, ReconcileSummary s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 20, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Deletes ${s.localNotes} note${s.localNotes == 1 ? '' : 's'} '
                'from this device and cannot be undone.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _confirmCtrl,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Type $_confirmWord to confirm',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

/// Prominent "back up first" callout shown above the wipe action.
class _BackupWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Save anything you want to keep first',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
                const SizedBox(height: 4),
                Text(
                  'Replacing is permanent — notes on this device that aren\'t '
                  'on a server will be lost. Before continuing, either:\n'
                  '• Cancel and sign back into the original account to sync '
                  'these notes, or\n'
                  '• Cancel and use Settings → “Back up to file”, then '
                  're-import after switching.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final ReconcileSummary summary;

  @override
  Widget build(BuildContext context) {
    String line(int notebooks, int notes) =>
        '$notebooks notebook${notebooks == 1 ? '' : 's'} · '
        '$notes note${notes == 1 ? '' : 's'}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smartphone_outlined),
              title: const Text('This device (will be discarded)'),
              subtitle: Text(line(summary.localNotebooks, summary.localNotes)),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('This account (will be loaded)'),
              subtitle:
                  Text(line(summary.serverNotebooks, summary.serverNotes)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            Text("Couldn't read the account data.\n$error",
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
