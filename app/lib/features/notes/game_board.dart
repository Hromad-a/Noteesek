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
/// Layout is width-aware (see [_ScoreLayout.forWidth]): with a few players the
/// columns share the available width so nothing scrolls sideways; only when
/// there are too many players to fit does the sheet scroll horizontally, and
/// then the left "Round" column is frozen so it stays in view.
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

/// Fixed left ("Round"/number/"Total") column width and the minimum a player
/// column may shrink to before the sheet starts scrolling sideways. Row heights
/// are fixed so the frozen left column and the scrolling player columns line up.
const double _leftW = 56;
const double _minColW = 64;
const double _headerH = 98;
const double _roundH = 54;
const double _totalsH = 48;

/// Resolved column width + whether the sheet has to scroll horizontally.
class _ScoreLayout {
  const _ScoreLayout(this.colW, this.scroll);
  final double colW;
  final bool scroll;

  /// Share [avail] among [players] columns; if that would make columns narrower
  /// than [_minColW], clamp to the minimum and scroll instead.
  factory _ScoreLayout.forWidth(double avail, int players) {
    final fit = (avail - _leftW) / players;
    if (fit >= _minColW) return _ScoreLayout(fit, false);
    return const _ScoreLayout(_minColW, true);
  }
}

class _GameBoardState extends State<GameBoard> {
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
      // Index the new round will occupy. A score controller may linger here from
      // a previously-removed round (they're not disposed on removal), so clear
      // its text — otherwise the fresh, zero-valued round shows the old number.
      final newRound = _game.rounds;
      for (final p in _game.players) {
        p.scores = [...p.scores, 0.0];
        _scoreCtrls['${p.id}:$newRound']?.text = '';
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

  /// Removing a round or player wipes a whole row/column of scores, so both are
  /// gated behind a confirmation (an easy mis-tap otherwise loses data).
  Future<bool> _confirm(String title) async =>
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
              child: Text(context.l10n.remove),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _confirmRemoveRound(int round) async {
    if (await _confirm(context.l10n.gameRemoveRoundConfirm('${round + 1}'))) {
      _removeRound(round);
    }
  }

  Future<void> _confirmRemovePlayer(GamePlayer p) async {
    final name = p.name.trim();
    final prompt = name.isEmpty
        ? context.l10n.gameRemovePlayerConfirmUnnamed
        : context.l10n.gameRemovePlayerConfirm(name);
    if (await _confirm(prompt)) _removePlayer(p);
  }

  void _onNameChanged(GamePlayer p, String value) {
    p.name = value;
    _persist();
    // Names don't affect totals, so no setState is required here — the
    // controller holds the text.
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

  /// The highest score in round [r], or null when no cell should be marked as
  /// the row leader — fewer than 2 players, or every value is equal (e.g. an
  /// untouched all-zero round). Cells equal to this value get the leader tint.
  double? _bestInRound(int r) {
    if (_game.players.length < 2) return null;
    double? maxV, minV;
    for (final p in _game.players) {
      final v = _game.scoreAt(p, r);
      maxV = (maxV == null || v > maxV) ? v : maxV;
      minV = (minV == null || v < minV) ? v : minV;
    }
    if (maxV == null || maxV == minV) return null;
    return maxV;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.readOnly) return _ReadOnlyBoard(body: widget.body);

    if (_game.players.isEmpty) {
      return _EmptyBoard(onAddPlayer: _addPlayer);
    }

    final theme = Theme.of(context);
    final rounds = _game.rounds;
    final ranks = _game.ranksByTotal();
    final divider = BorderSide(color: theme.dividerColor);

    // --- left ("Round" / number / "Total") column cells --------------------
    Widget leftCell(double height, Widget child, {BoxBorder? border}) =>
        Container(
          width: _leftW,
          height: height,
          alignment: Alignment.centerLeft,
          decoration: border == null ? null : BoxDecoration(border: border),
          padding: const EdgeInsets.only(right: 4),
          child: child,
        );

    final headerLeft = leftCell(
      _headerH,
      Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(context.l10n.gameRound,
              style: theme.textTheme.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ),
      border: Border(bottom: divider),
    );

    Widget roundLeft(int r) => leftCell(
          _roundH,
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.remove_circle_outline, size: 16),
                tooltip: context.l10n.gameRemoveRound,
                onPressed: () => _confirmRemoveRound(r),
              ),
              Text('${r + 1}', style: theme.textTheme.bodyMedium),
            ],
          ),
        );

    final totalsLeft = leftCell(
      _totalsH,
      Text(context.l10n.gameTotal, style: theme.textTheme.labelLarge, maxLines: 1),
      border: Border(top: divider),
    );

    // --- player column cells -----------------------------------------------
    Widget playerCell(double width, double height, Widget child,
            {BoxBorder? border}) =>
        Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: border == null ? null : BoxDecoration(border: border),
          child: child,
        );

    Widget headerPlayer(GamePlayer p, double colW) => playerCell(
          colW,
          _headerH,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Remove (X) on top, then the rank badge, then the name — all
              // centered in the column.
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.close, size: 16),
                tooltip: context.l10n.gameRemovePlayer,
                onPressed: () => _confirmRemovePlayer(p),
              ),
              _RankBadge(rank: ranks[p.id] ?? 0),
              const SizedBox(height: 2),
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
          border: Border(bottom: divider),
        );

    Widget scorePlayer(GamePlayer p, int r, double colW) {
      final best = _bestInRound(r);
      final isBest = best != null && _game.scoreAt(p, r) == best;
      final scheme = theme.colorScheme;
      return playerCell(
        colW,
        _roundH,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: TextField(
            controller: _scoreCtrl(p, r),
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(
                signed: true, decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
            ],
            // Entered values read stronger; the "0" placeholder is faded.
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
            decoration: InputDecoration(
              isDense: true,
              // The row leader's outline is only a hair warmer than a normal
              // cell (a ~20% nudge toward tertiary) — enough to spot, not enough
              // to look like the focused field's outline.
              filled: isBest,
              fillColor: isBest
                  ? scheme.tertiary.withValues(alpha: 0.04)
                  : null,
              border: const OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: isBest
                    ? BorderSide(
                        color: Color.lerp(
                            scheme.outlineVariant, scheme.tertiary, 0.2)!,
                        width: 1.2)
                    : BorderSide(color: scheme.outlineVariant),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              hintText: '0',
              hintStyle: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                fontWeight: FontWeight.w400,
              ),
            ),
            onChanged: (v) => _onScoreChanged(p, r, v),
          ),
        ),
      );
    }

    Widget totalsPlayer(GamePlayer p, double colW) => playerCell(
          colW,
          _totalsH,
          Text(
            formatGameScore(p.total),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          border: Border(top: divider),
        );

    final layout =
        _ScoreLayout.forWidth(_tableWidth(context), _game.players.length);

    Widget table;
    if (!layout.scroll) {
      // Everything fits: one plain table, no horizontal scroll.
      final colW = layout.colW;
      table = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            headerLeft,
            for (final p in _game.players) headerPlayer(p, colW),
          ]),
          for (var r = 0; r < rounds; r++)
            Row(children: [
              roundLeft(r),
              for (final p in _game.players) scorePlayer(p, r, colW),
            ]),
          Row(children: [
            totalsLeft,
            for (final p in _game.players) totalsPlayer(p, colW),
          ]),
        ],
      );
    } else {
      // Too many players: freeze the left column, scroll the players.
      final colW = layout.colW;
      table = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              headerLeft,
              for (var r = 0; r < rounds; r++) roundLeft(r),
              totalsLeft,
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    for (final p in _game.players) headerPlayer(p, colW),
                  ]),
                  for (var r = 0; r < rounds; r++)
                    Row(children: [
                      for (final p in _game.players) scorePlayer(p, r, colW),
                    ]),
                  Row(children: [
                    for (final p in _game.players) totalsPlayer(p, colW),
                  ]),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Tapping empty space (anywhere not a field/button) drops focus out of the
    // score/name field being edited and dismisses the keyboard.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusScope.of(context).unfocus(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          table,
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
      ),
    );
  }

  /// Width available to the table = the ListView's content box (screen minus its
  /// 16px side padding).
  double _tableWidth(BuildContext context) =>
      MediaQuery.of(context).size.width - 32;
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

/// Static, non-editable render of a game (read-only shared note). Uses the same
/// fit / freeze-left-column layout as the editor.
class _ReadOnlyBoard extends StatelessWidget {
  const _ReadOnlyBoard({required this.body});
  final String body;

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
    final rounds = game.rounds;
    final ranks = game.ranksByTotal();
    final divider = BorderSide(color: theme.dividerColor);
    final scheme = theme.colorScheme;

    // Highest value in a round, or null when nothing should be marked (see the
    // editor's _bestInRound).
    double? bestInRound(int r) {
      if (game.players.length < 2) return null;
      double? maxV, minV;
      for (final p in game.players) {
        final v = game.scoreAt(p, r);
        maxV = (maxV == null || v > maxV) ? v : maxV;
        minV = (minV == null || v < minV) ? v : minV;
      }
      if (maxV == null || maxV == minV) return null;
      return maxV;
    }

    Widget leftCell(double height, Widget child, {BoxBorder? border}) =>
        Container(
          width: _leftW,
          height: height,
          alignment: Alignment.centerLeft,
          decoration: border == null ? null : BoxDecoration(border: border),
          padding: const EdgeInsets.only(right: 4),
          child: child,
        );

    Widget playerCell(double width, double height, Widget child,
            {BoxBorder? border}) =>
        Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: border == null ? null : BoxDecoration(border: border),
          child: child,
        );

    final headerLeft = leftCell(
      _headerH,
      Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(context.l10n.gameRound,
              style: theme.textTheme.labelMedium),
        ),
      ),
      border: Border(bottom: divider),
    );
    Widget roundLeft(int r) => leftCell(
        _roundH,
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text('${r + 1}', style: theme.textTheme.bodyMedium),
        ));
    final totalsLeft = leftCell(
      _totalsH,
      Text(context.l10n.gameTotal, style: theme.textTheme.labelLarge, maxLines: 1),
      border: Border(top: divider),
    );

    Widget headerPlayer(GamePlayer p, double colW) => playerCell(
          colW,
          _headerH,
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
          border: Border(bottom: divider),
        );
    Widget scorePlayer(GamePlayer p, int r, double colW) {
      final v = game.scoreAt(p, r);
      final best = bestInRound(r);
      final isBest = best != null && v == best;
      final isZero = v == 0;
      return playerCell(
        colW,
        _roundH,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: isBest ? scheme.tertiary.withValues(alpha: 0.04) : null,
              border: Border.all(
                color: isBest
                    ? Color.lerp(
                        scheme.outlineVariant, scheme.tertiary, 0.2)!
                    : scheme.outlineVariant,
                width: isBest ? 1.2 : 1,
              ),
            ),
            child: Text(
              formatGameScore(v),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: isZero ? FontWeight.w400 : FontWeight.w600,
                color: isZero
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
                    : scheme.onSurface,
              ),
            ),
          ),
        ),
      );
    }
    Widget totalsPlayer(GamePlayer p, double colW) => playerCell(
          colW,
          _totalsH,
          Text(formatGameScore(p.total),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          border: Border(top: divider),
        );

    final layout =
        _ScoreLayout.forWidth(MediaQuery.of(context).size.width - 32,
            game.players.length);

    Widget table;
    if (!layout.scroll) {
      final colW = layout.colW;
      table = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            headerLeft,
            for (final p in game.players) headerPlayer(p, colW),
          ]),
          for (var r = 0; r < rounds; r++)
            Row(children: [
              roundLeft(r),
              for (final p in game.players) scorePlayer(p, r, colW),
            ]),
          Row(children: [
            totalsLeft,
            for (final p in game.players) totalsPlayer(p, colW),
          ]),
        ],
      );
    } else {
      final colW = layout.colW;
      table = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              headerLeft,
              for (var r = 0; r < rounds; r++) roundLeft(r),
              totalsLeft,
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    for (final p in game.players) headerPlayer(p, colW),
                  ]),
                  for (var r = 0; r < rounds; r++)
                    Row(children: [
                      for (final p in game.players) scorePlayer(p, r, colW),
                    ]),
                  Row(children: [
                    for (final p in game.players) totalsPlayer(p, colW),
                  ]),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [table],
    );
  }
}
