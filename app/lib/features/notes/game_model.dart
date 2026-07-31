import 'dart:convert';

/// Pure model + (de)serialization for a **game** note — a score counter for
/// playing games. No Flutter imports so it stays trivially unit-testable and is
/// reused by the editor, the card preview and the exporters.
///
/// A game note keeps all of its state as a small JSON document in the note's
/// `body` field (a note of `type == 'game'`). That means it rides the existing
/// note last-write-wins sync, JSON/zip backup, server snapshots and restore for
/// free — none of that machinery needs to know games exist. The layout is:
///
/// ```json
/// { "v": 1, "players": [ { "id": "abc", "name": "Alice", "scores": [10, 5.5] } ] }
/// ```
///
/// Rounds are implicit columns: the round count is the longest player's
/// `scores` list, and a player with a shorter list simply scored 0 in the
/// rounds beyond their list. Totals are the sum of a player's scores; the rank
/// badge orders players by total (highest total = rank 1, ties share a rank),
/// but the players themselves stay in the order they were added.

/// One player in a game note. Mutable so the editor can edit in place before
/// re-encoding to the note body.
class GamePlayer {
  GamePlayer({required this.id, required this.name, required this.scores});

  final String id;
  String name;

  /// One entry per round played; `scores[r]` is this player's score in round r.
  List<double> scores;

  double get total => scores.fold(0.0, (a, b) => a + b);
}

/// The parsed state of a game note.
class GameState {
  GameState({required this.players});

  final List<GamePlayer> players;

  /// The number of rounds = the longest player's score list.
  int get rounds =>
      players.fold(0, (m, p) => p.scores.length > m ? p.scores.length : m);

  /// [player]'s score in [round], or 0 when that round is blank for them.
  double scoreAt(GamePlayer player, int round) =>
      round >= 0 && round < player.scores.length ? player.scores[round] : 0.0;

  /// 1-based rank of each player id by total, highest total first. Tied totals
  /// share the same rank (e.g. 1, 1, 3). Empty when there are no players.
  Map<String, int> ranksByTotal() {
    final sorted = [...players]..sort((a, b) => b.total.compareTo(a.total));
    final result = <String, int>{};
    var rank = 0;
    double? prevTotal;
    for (var i = 0; i < sorted.length; i++) {
      final t = sorted[i].total;
      if (prevTotal == null || t != prevTotal) {
        rank = i + 1;
        prevTotal = t;
      }
      result[sorted[i].id] = rank;
    }
    return result;
  }

  /// True when the note holds nothing worth keeping: no players, or only blank
  /// players with no non-zero scores. Drives the "empty note auto-trash" rule.
  bool get isEmpty => players.every(
      (p) => p.name.trim().isEmpty && p.scores.every((s) => s == 0));
}

/// Parses a game note [body]. Tolerant of an empty/malformed value (returns an
/// empty game) so a brand-new note (empty body) opens as a fresh board.
GameState parseGame(String body) {
  if (body.trim().isEmpty) return GameState(players: []);
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['players'] is List) {
      final players = <GamePlayer>[];
      for (final raw in decoded['players'] as List) {
        if (raw is! Map) continue;
        final scores = <double>[
          for (final s in (raw['scores'] as List?) ?? const [])
            (s as num?)?.toDouble() ?? 0.0,
        ];
        players.add(GamePlayer(
          id: raw['id']?.toString() ?? '',
          name: raw['name']?.toString() ?? '',
          scores: scores,
        ));
      }
      return GameState(players: players);
    }
  } catch (_) {/* fall through to empty */}
  return GameState(players: []);
}

/// Encodes [game] back into the JSON stored in the note body. Whole-number
/// scores are written as ints (`10`, not `10.0`) to keep the JSON tidy.
String encodeGame(GameState game) => jsonEncode({
      'v': 1,
      'players': [
        for (final p in game.players)
          {
            'id': p.id,
            'name': p.name,
            'scores': [for (final s in p.scores) _compact(s)],
          },
      ],
    });

/// A score as an int when it has no fractional part, else the double itself.
num _compact(double s) => s == s.roundToDouble() && s.isFinite ? s.toInt() : s;

/// Formats a score for display: no trailing `.0` on whole numbers, otherwise up
/// to two decimals with trailing zeros trimmed (e.g. `5`, `5.5`, `-2.25`).
String formatGameScore(double s) {
  if (s == s.roundToDouble() && s.isFinite) return s.toInt().toString();
  var str = s.toStringAsFixed(2);
  str = str.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  return str;
}

/// Renders a game as a GitHub-flavoured Markdown table (for note export). Rows
/// are rounds, columns are players, with a final **Total** row. Returns an empty
/// string when there are no players.
String gameMarkdownTable(GameState game) {
  if (game.players.isEmpty) return '';
  final buf = StringBuffer();
  String cell(String s) => s.replaceAll('|', r'\|');

  final headers = ['Round', ...game.players.map((p) => cell(p.name))];
  buf.writeln('| ${headers.join(' | ')} |');
  buf.writeln('| ${List.filled(headers.length, '---').join(' | ')} |');
  for (var r = 0; r < game.rounds; r++) {
    final row = [
      '${r + 1}',
      for (final p in game.players) formatGameScore(game.scoreAt(p, r)),
    ];
    buf.writeln('| ${row.join(' | ')} |');
  }
  final totals = [
    'Total',
    for (final p in game.players) formatGameScore(p.total),
  ];
  buf.writeln('| ${totals.join(' | ')} |');
  return buf.toString();
}

/// Renders a game as plain text (for the "share as text" action): each player
/// in their added order, prefixed with their rank number. Empty when no players.
String gamePlainText(GameState game) {
  if (game.players.isEmpty) return '';
  final ranks = game.ranksByTotal();
  final buf = StringBuffer();
  for (final p in game.players) {
    final name = p.name.trim().isEmpty ? '—' : p.name.trim();
    buf.writeln('${ranks[p.id]}. $name: ${formatGameScore(p.total)}');
  }
  return buf.toString().trimRight();
}
