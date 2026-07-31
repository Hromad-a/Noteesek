import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/local/ids.dart';
import '../../data/notes_repository.dart';
import '../../l10n/l10n.dart';
import 'farkle_model.dart';

/// The editor for a **farkle** note — a turn-based score tracker. Strict turn
/// order: only the active player's card shows the scoring controls; the others
/// collapse to name + score. Every edit re-encodes the whole state and saves it
/// into the note body via [NotesRepository.updateNoteFields] (the note's normal
/// autosave path), so a farkle note rides the same sync/backup as any other note.
///
/// State is seeded once from [body]; thereafter the widget owns it. When
/// [readOnly] (a shared note someone else is editing) it renders a static view.
class FarkleBoard extends StatefulWidget {
  const FarkleBoard({
    super.key,
    required this.noteId,
    required this.repo,
    required this.body,
    this.readOnly = false,
  });

  final String noteId;
  final NotesRepository repo;
  final String body;
  final bool readOnly;

  @override
  State<FarkleBoard> createState() => _FarkleBoardState();
}

class _FarkleBoardState extends State<FarkleBoard> {
  late FarkleState _state;
  final Map<String, TextEditingController> _nameCtrls = {};
  final TextEditingController _customCtrl = TextEditingController();
  late final TextEditingController _targetCtrl;

  @override
  void initState() {
    super.initState();
    _state = parseFarkle(widget.body);
    _targetCtrl = TextEditingController(text: _state.target.toString());
  }

  @override
  void dispose() {
    for (final c in _nameCtrls.values) {
      c.dispose();
    }
    _customCtrl.dispose();
    _targetCtrl.dispose();
    super.dispose();
  }

  void _persist() =>
      widget.repo.updateNoteFields(widget.noteId, body: encodeFarkle(_state));

  void _mutate(VoidCallback change) {
    setState(change);
    _persist();
  }

  TextEditingController _nameCtrl(FarklePlayer p) =>
      _nameCtrls.putIfAbsent(p.id, () => TextEditingController(text: p.name));

  Future<bool> _confirm(String title, String confirmLabel) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  void _addPlayer() => _mutate(() => _state.addPlayer(newPbId()));

  Future<void> _removePlayer(FarklePlayer p) async {
    final name = p.name.trim();
    final prompt = name.isEmpty
        ? context.l10n.gameRemovePlayerConfirmUnnamed
        : context.l10n.gameRemovePlayerConfirm(name);
    if (await _confirm(prompt, context.l10n.remove)) {
      _nameCtrls.remove(p.id)?.dispose();
      _mutate(() => _state.removePlayer(p.id));
    }
  }

  void _onName(FarklePlayer p, String v) {
    p.name = v;
    _persist(); // no setState: the controller holds the text
  }

  void _onTarget(String v) {
    final t = int.tryParse(v.trim());
    if (t != null && t > 0) _mutate(() => _state.setTarget(t));
  }

  void _addToTurn(int delta) => _mutate(() => _state.addToTurn(delta));

  void _addCustom() {
    final v = int.tryParse(_customCtrl.text.trim());
    if (v != null && v != 0) {
      _customCtrl.clear();
      _addToTurn(v);
    }
  }

  void _confirmTurn() => _mutate(_state.confirmTurn);
  void _farkle() => _mutate(_state.farkle);

  Future<void> _newGame() async {
    if (await _confirm(
        context.l10n.farkleNewGameConfirm, context.l10n.farkleNewGame)) {
      _mutate(_state.resetGame);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.readOnly) return _ReadOnlyFarkle(body: widget.body);
    if (_state.players.isEmpty) return _EmptyBoard(onAddPlayer: _addPlayer);

    final places = farklePlaces(_state);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _topBar(),
          if (_state.ended) ...[
            const SizedBox(height: 12),
            _standingsBanner(places),
          ],
          const SizedBox(height: 12),
          for (var i = 0; i < _state.players.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _playerCard(_state.players[i], i, places),
            ),
        ],
      ),
    );
  }

  Widget _topBar() {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _targetCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              isDense: true,
              labelText: context.l10n.farkleTarget,
              border: const OutlineInputBorder(),
            ),
            onChanged: _onTarget,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: context.l10n.gameAddPlayer,
          icon: const Icon(Icons.person_add_alt_1),
          onPressed: _addPlayer,
        ),
        TextButton(
          onPressed: _newGame,
          child: Text(context.l10n.farkleNewGame,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      ],
    );
  }

  Widget _standingsBanner(Map<String, int> places) {
    final theme = Theme.of(context);
    final order = _state.standings();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.farkleResults,
              style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final p in order)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  _PlaceBadge(place: places[p.id] ?? 0),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      p.name.trim().isEmpty ? '—' : p.name.trim(),
                      style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer),
                    ),
                  ),
                  Text(formatFarkleScore(p.score),
                      style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _playerCard(FarklePlayer p, int index, Map<String, int> places) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isActive = index == _state.currentIdx && !p.finished && !_state.ended;

    final header = Row(
      children: [
        _PlaceBadge(place: places[p.id] ?? 0, finished: p.finished),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _nameCtrl(p),
            style: theme.textTheme.titleMedium,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: context.l10n.gamePlayerHint,
            ),
            onChanged: (v) => _onName(p, v),
          ),
        ),
        Text(formatFarkleScore(p.score),
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 18),
          tooltip: context.l10n.gameRemovePlayer,
          onPressed: () => _removePlayer(p),
        ),
      ],
    );

    return Opacity(
      opacity: p.finished ? 0.6 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        decoration: BoxDecoration(
          color: isActive ? scheme.surfaceContainerHighest : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? scheme.primary : scheme.outlineVariant,
            width: isActive ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isActive)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 2),
                child: Text(context.l10n.farkleOnTurn,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.primary)),
              ),
            Padding(padding: const EdgeInsets.only(right: 8), child: header),
            if (isActive) ...[
              const SizedBox(height: 8),
              _thisTurnBox(p),
              const SizedBox(height: 8),
              _scoreButtons(),
              const SizedBox(height: 8),
              _customRow(),
              const SizedBox(height: 8),
              _actionRow(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _thisTurnBox(FarklePlayer p) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(context.l10n.farkleThisTurn,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
          Text(
            formatFarkleScore(p.turnScore),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: p.turnScore > 0 ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreButtons() {
    Widget btn(int delta) {
      final pos = delta > 0;
      return OutlinedButton(
        onPressed: () => _addToTurn(delta),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          foregroundColor: pos
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
        child: Text('${pos ? '+' : ''}$delta'),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        children: [
          Row(
            children: [
              for (final d in kFarklePosPresets) ...[
                Expanded(child: btn(d)),
                const SizedBox(width: 6),
              ],
            ]..removeLast(),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final d in kFarkleNegPresets) ...[
                Expanded(child: btn(d)),
                const SizedBox(width: 6),
              ],
            ]..removeLast(),
          ),
        ],
      ),
    );
  }

  Widget _customRow() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: TextField(
              controller: _customCtrl,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9\-]')),
              ],
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: context.l10n.farkleCustom,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
              onSubmitted: (_) => _addCustom(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _addCustom,
              icon: const Icon(Icons.add, size: 18),
              label: Text(context.l10n.add),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _confirmTurn,
              icon: const Icon(Icons.check),
              label: Text(context.l10n.farkleConfirm),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _farkle,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              icon: const Icon(Icons.close),
              label: Text(context.l10n.farkleBust),
            ),
          ),
        ],
      ),
    );
  }
}

/// The small circular place number shown next to a player.
class _PlaceBadge extends StatelessWidget {
  const _PlaceBadge({required this.place, this.finished = false});
  final int place;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (place <= 0) return const SizedBox(width: 26);
    final leader = place == 1 && finished;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: leader ? scheme.primary : scheme.surfaceContainerHighest,
      ),
      child: Text(
        '$place',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: leader ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Shown when a farkle note has no players yet.
class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard({required this.onAddPlayer});
  final VoidCallback onAddPlayer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.casino_outlined, size: 64, color: theme.disabledColor),
            const SizedBox(height: 16),
            Text(context.l10n.gameNoPlayers,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(context.l10n.gameAddPlayer),
              onPressed: onAddPlayer,
            ),
          ],
        ),
      ),
    );
  }
}

/// Static, non-editable render of a farkle note (read-only shared note): the
/// standings only.
class _ReadOnlyFarkle extends StatelessWidget {
  const _ReadOnlyFarkle({required this.body});
  final String body;

  @override
  Widget build(BuildContext context) {
    final state = parseFarkle(body);
    final theme = Theme.of(context);
    if (state.players.isEmpty) {
      return Center(
        child: Text(context.l10n.gameNoPlayersShort,
            style: TextStyle(color: theme.disabledColor)),
      );
    }
    final places = farklePlaces(state);
    final order = state.standings();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        for (final p in order)
          ListTile(
            leading: _PlaceBadge(place: places[p.id] ?? 0, finished: p.finished),
            title: Text(p.name.trim().isEmpty ? '—' : p.name.trim()),
            trailing: Text(formatFarkleScore(p.score),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
      ],
    );
  }
}
