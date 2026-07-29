import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/local/ids.dart';
import '../../data/notes_repository.dart';
import '../../l10n/l10n.dart';
import 'game_model.dart';

/// The scoresheet editor for a `game` note. Rows are rounds, columns are
/// players; a **Total** row sits at the bottom and each player carries a rank
/// badge (by total, highest first — players keep their added order). Every edit
/// re-encodes the whole game and saves it into the note body via
/// [NotesRepository.updateNoteFields] (the note's normal autosave path), so a
/// game rides the same sync/backup as any other note.
///
/// State is seeded once from [body]; thereafter the widget owns it (like the
/// text editor's controller). When [readOnly] (a shared note someone else is
/// editing) it renders a static view straight from [body] instead.
class GameBoard extends StatefulWidget {
  const GameBoard({
    super.key,
    required this.noteId,
    required this.repo,
    required this.body,
    this.readOnly = false,
  });

  final String noteId;
  final NotesRepository repo;

  /// The note's current body (the game JSON). Seeds the editable state once; in
  /// read-only mode it's re-read on every build so live updates show.
  final String body;
  final bool readOnly;

  @override
  State<GameBoard> createState() => _GameBoardState();
}

class _GameBoardState extends State<GameBoard> {
  static const double _leftW = 72;
  static const double _colW = 108;

  late GameState _game;
  final Map<String, TextEditingController> _nameCtrls = {};
  final Map<String, TextEditingController> _scoreCtrls = {};

  @override
  void initState() {
    super.initState();
    _game = parseGame(widget.body);
    _normalize();
  }

  @override
  void dispose() {
    for (final c in _nameCtrls.values) {
      c.dispose();
    }
    for (final c in _scoreCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Pad every player's score list to the current round count so cell indexing
  /// is uniform (a missing round already counts as 0).
  void _normalize() {
    final rounds = _game.rounds;
    for (final p in _game.players) {
      if (p.scores.length < rounds) {
        p.scores = [
          ...p.scores,
          ...List<double>.filled(rounds - p.scores.length, 0.0),
        ];
      }
    }
  }

  void _persist() {
    widget.repo.updateNoteFields(widget.noteId, body: encodeGame(_game));
  }

  /// After a round is removed the round indices shift, so the existing per-cell
  /// controllers (keyed by round index) now map to different values — reseed
  /// their text from state. Controllers keyed to a now-out-of-range round are
  /// simply left unused (disposed with the widget) to avoid disposing one that a
  /// still-mounted field references.
  void _reseedScoreCtrls() {
    final rounds = _game.rounds;
    for (final p in _game.players) {
      for (var r = 0; r < rounds; r++) {
        final c = _scoreCtrls['${p.id}:$r'];
        if (c == null) continue;
        final v = _game.scoreAt(p, r);
        final text = v == 0 ? '' : formatGameScore(v);
        if (c.text != text) c.text = text;
      }
    }
  }

  TextEditingController _nameCtrl(GamePlayer p) =>
      _nameCtrls.putIfAbsent(p.id, () => TextEditingController(text: p.name));

  TextEditingController _scoreCtrl(GamePlayer p, int round) {
    final key = '${p.id}:$round';
    return _scoreCtrls.putIfAbsent(key, () {
      final v = _game.scoreAt(p, round);
      return TextEditingController(text: v == 0 ? '' : formatGameScore(v));
    });
  }

  void _addPlayer() {
    setState(() {
      _game.players.add(GamePlayer(
        id: newPbId(),
        name: '',
        scores: List<double>.filled(_game.rounds, 0.0),
      ));
    });
    _persist();
  }

  void _removePlayer(GamePlayer p) {
    setState(() {
      _game.players.removeWhere((x) => x.id == p.id);
      _nameCtrls.remove(p.id)?.dispose();
      // This player's score controllers are keyed by its id, so removing the
      // player leaves them orphaned (unused); other players' cells are keyed by
      // their own id + round and are unaffected. No reseed needed.
    });
    _persist();
  }

  void _addRound() {
    setState(() {
      for (final p in _game.players) {
        p.scores = [...p.scores, 0.0];
      }
    });
    _persist();
  }

  void _removeRound(int round) {
    setState(() {
      for (final p in _game.players) {
        if (round < p.scores.length) p.scores.removeAt(round);
      }
      _reseedScoreCtrls(); // round indices shifted down
    });
    _persist();
  }

  void _onNameChanged(GamePlayer p, String value) {
    p.name = value;
    _persist();
    // Rebuild so nothing else is needed, but keep it cheap: names don't affect
    // totals, so no setState is required here — the controller holds the text.
  }

  void _onScoreChanged(GamePlayer p, int round, String value) {
    // Pad if this player was short for this round, then store the parsed value.
    // Incomplete input ("", "-", "1.") parses to 0 for the running total but the
    // field keeps its raw text so the user can finish typing.
    while (p.scores.length <= round) {
      p.scores.add(0.0);
    }
    p.scores[round] = double.tryParse(value.replaceAll(',', '.')) ?? 0.0;
    _persist();
    setState(() {}); // refresh totals + rank badges
  }

  @override
  Widget build(BuildContext context) {
    if (widget.readOnly) return _ReadOnlyBoard(body: widget.body);

    if (_game.players.isEmpty) {
      return _EmptyBoard(onAddPlayer: _addPlayer);
    }

    final rounds = _game.rounds;
    final ranks = _game.ranksByTotal();
    final theme = Theme.of(context);

    Widget cell(double width, Widget child, {Alignment? align}) => SizedBox(
          width: width,
          child: Align(
            alignment: align ?? Alignment.center,
            child: child,
          ),
        );

    // Header: leftmost "Round" label, then each player's name + rank badge.
    final header = Row(
      children: [
        cell(
          _leftW,
          Text(context.l10n.gameRound,
              style: theme.textTheme.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          align: Alignment.centerLeft,
        ),
        for (final p in _game.players)
          cell(
            _colW,
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RankBadge(rank: ranks[p.id] ?? 0),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: context.l10n.gameRemovePlayer,
                      onPressed: () => _removePlayer(p),
                    ),
                  ],
                ),
                TextField(
                  controller: _nameCtrl(p),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: context.l10n.gamePlayerHint,
                  ),
                  onChanged: (v) => _onNameChanged(p, v),
                ),
              ],
            ),
          ),
      ],
    );

    // One row per round: the round number (with a remove button) then a score
    // field per player.
    Widget roundRow(int r) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              cell(
                _leftW,
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      icon: const Icon(Icons.remove_circle_outline, size: 16),
                      tooltip: context.l10n.gameRemoveRound,
                      onPressed: () => _removeRound(r),
                    ),
                    Text('${r + 1}', style: theme.textTheme.bodyMedium),
                  ],
                ),
                align: Alignment.centerLeft,
              ),
              for (final p in _game.players)
                cell(
                  _colW,
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextField(
                      controller: _scoreCtrl(p, r),
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                          signed: true, decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.,\-]')),
                      ],
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        hintText: '0',
                      ),
                      onChanged: (v) => _onScoreChanged(p, r, v),
                    ),
                  ),
                ),
            ],
          ),
        );

    // Totals row.
    final totals = Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.dividerColor),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          cell(
            _leftW,
            Text(context.l10n.gameTotal,
                style: theme.textTheme.labelLarge, maxLines: 1),
            align: Alignment.centerLeft,
          ),
          for (final p in _game.players)
            cell(
              _colW,
              Text(
                formatGameScore(p.total),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );

    final tableWidth = _leftW + _colW * _game.players.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth < MediaQuery.of(context).size.width - 32
                ? null
                : tableWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const Divider(),
                for (var r = 0; r < rounds; r++) roundRow(r),
                totals,
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(context.l10n.gameAddPlayer),
              onPressed: _addPlayer,
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.add),
              label: Text(context.l10n.gameAddRound),
              onPressed: _addRound,
            ),
          ],
        ),
      ],
    );
  }
}

/// The small circular rank number shown next to a player.
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});
  final int rank;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (rank <= 0) return const SizedBox(width: 22);
    // The leader is highlighted more strongly than the rest.
    final leader = rank == 1;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: leader ? scheme.primary : scheme.surfaceContainerHighest,
      ),
      child: Text(
        '$rank',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: leader ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Shown when a game note has no players yet.
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
            Icon(Icons.scoreboard_outlined,
                size: 64, color: theme.disabledColor),
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

/// Static, non-editable render of a game (read-only shared note).
class _ReadOnlyBoard extends StatelessWidget {
  const _ReadOnlyBoard({required this.body});
  final String body;

  static const double _leftW = 72;
  static const double _colW = 108;

  @override
  Widget build(BuildContext context) {
    final game = parseGame(body);
    final theme = Theme.of(context);
    if (game.players.isEmpty) {
      return Center(
        child: Text(context.l10n.gameNoPlayersShort,
            style: TextStyle(color: theme.disabledColor)),
      );
    }
    final ranks = game.ranksByTotal();

    Widget cell(Widget child, {double? width, Alignment align = Alignment.center}) =>
        SizedBox(width: width, child: Align(alignment: align, child: child));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  cell(Text(context.l10n.gameRound,
                      style: theme.textTheme.labelMedium),
                      width: _leftW, align: Alignment.centerLeft),
                  for (final p in game.players)
                    cell(
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RankBadge(rank: ranks[p.id] ?? 0),
                          Text(
                            p.name.trim().isEmpty ? '—' : p.name.trim(),
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      width: _colW,
                    ),
                ],
              ),
              const Divider(),
              for (var r = 0; r < game.rounds; r++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      cell(Text('${r + 1}', style: theme.textTheme.bodyMedium),
                          width: _leftW, align: Alignment.centerLeft),
                      for (final p in game.players)
                        cell(
                            Text(formatGameScore(game.scoreAt(p, r)),
                                style: theme.textTheme.bodyMedium),
                            width: _colW),
                    ],
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    cell(Text(context.l10n.gameTotal,
                        style: theme.textTheme.labelLarge),
                        width: _leftW, align: Alignment.centerLeft),
                    for (final p in game.players)
                      cell(
                          Text(formatGameScore(p.total),
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          width: _colW),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
