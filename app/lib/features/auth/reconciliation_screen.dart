import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/notes_repository.dart';
import '../../providers.dart';
import '../../sync/reconciliation_service.dart';
import '../../sync/sync_controller.dart';

/// Shown on mobile sign-in when the device holds data that diverges from the
/// account's server data (see docs/sign-in-reconciliation.md). Lets the user
/// choose how to reconcile. Pops `true` once a strategy has run, `false` if the
/// user cancels (the caller then undoes the sign-in).
///
/// Phase 1: **Merge** is functional; the destructive options are shown but
/// disabled until their phases land.
class ReconciliationScreen extends ConsumerStatefulWidget {
  const ReconciliationScreen({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<ReconciliationScreen> createState() =>
      _ReconciliationScreenState();
}

enum _Strategy { merge, keepLocal, keepServer }

class _ReconciliationScreenState extends ConsumerState<ReconciliationScreen> {
  ReconciliationService get _service => ReconciliationService(
        ref.read(databaseProvider),
        ref.read(notesRepositoryProvider),
        ref.read(pocketBaseProvider),
        ref.read(syncEngineProvider),
      );

  ReconcileSummary? _summary;
  Object? _inspectError;
  _Strategy _selected = _Strategy.merge;
  bool _running = false;

  /// Word the user must type to enable a destructive choice.
  static const _confirmWord = 'REPLACE';
  final _confirmCtrl = TextEditingController();

  bool get _isDestructive =>
      _selected == _Strategy.keepLocal || _selected == _Strategy.keepServer;

  bool get _canContinue =>
      !_isDestructive ||
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

  void _select(_Strategy s) {
    setState(() {
      _selected = s;
      _confirmCtrl.clear();
    });
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      switch (_selected) {
        case _Strategy.merge:
          await _service.merge(userId: widget.userId);
        case _Strategy.keepServer:
          await _service.keepServerReplace();
        case _Strategy.keepLocal:
          await _service.keepLocalMirror(userId: widget.userId);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Reconcile failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // a choice (or Cancel) must be made; no silent back-out
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reconcile your data'),
          automaticallyImplyLeading: false,
        ),
        body: _inspectError != null
            ? _ErrorBody(error: _inspectError!, onRetry: _inspect)
            : _summary == null
                ? const Center(child: CircularProgressIndicator())
                : _buildChooser(context, _summary!),
      ),
    );
  }

  Widget _buildChooser(BuildContext context, ReconcileSummary s) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'You have data on this device to reconcile with this account.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            _SummaryCard(summary: s),
            const SizedBox(height: 24),
            _OptionTile(
              title: 'Merge — keep everything',
              subtitle:
                  "Combine this device's data with the account's. Nothing is "
                  'deleted.',
              icon: Icons.merge_outlined,
              recommended: true,
              selected: _selected == _Strategy.merge,
              onTap: () => _select(_Strategy.merge),
            ),
            _OptionTile(
              title: 'Keep this device only',
              subtitle: 'Make the server match this device. '
                  '${s.serverOnly} item${s.serverOnly == 1 ? '' : 's'} on the '
                  'server ${s.serverOnly == 1 ? "isn't" : "aren't"} here and '
                  'will be deleted.',
              icon: Icons.smartphone_outlined,
              selected: _selected == _Strategy.keepLocal,
              onTap: () => _select(_Strategy.keepLocal),
            ),
            _OptionTile(
              title: 'Keep the server only',
              subtitle: 'Replace this device with the server. '
                  '${s.localOnly} item${s.localOnly == 1 ? '' : 's'} here '
                  '${s.localOnly == 1 ? "isn't" : "aren't"} on the server and '
                  'will be lost.',
              icon: Icons.cloud_download_outlined,
              selected: _selected == _Strategy.keepServer,
              onTap: () => _select(_Strategy.keepServer),
            ),
            if (_isDestructive) _confirmGuard(context),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: (_running || !_canContinue) ? null : _run,
              child: const Text('Continue'),
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
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    switch (_selected) {
                      _Strategy.keepServer => 'Replacing…',
                      _Strategy.keepLocal => 'Updating the server…',
                      _Strategy.merge => 'Merging…',
                    },
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Type-to-confirm gate shown for the destructive options.
  Widget _confirmGuard(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 20, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This permanently deletes data and cannot be undone.',
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
              title: const Text('This device'),
              subtitle: Text(
                line(summary.localNotebooks, summary.localNotes) +
                    (summary.foreignItems > 0
                        ? '  ·  ${summary.foreignItems} from another account or offline'
                        : ''),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('This account (server)'),
              subtitle:
                  Text(line(summary.serverNotebooks, summary.serverNotes)),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.recommended = false,
    this.selected = false,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool recommended;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        leading: Icon(icon),
        title: Row(
          children: [
            Flexible(child: Text(title)),
            if (recommended) ...[
              const SizedBox(width: 8),
              Chip(
                label: const Text('Recommended'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                labelStyle: theme.textTheme.labelSmall,
              ),
            ],
          ],
        ),
        subtitle: Text(subtitle),
        trailing: selected
            ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
            : const Icon(Icons.radio_button_unchecked),
        onTap: onTap,
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
