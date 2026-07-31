import 'dart:convert';

/// Pure model + (de)serialization for a **farkle** note — a turn-based score
/// tracker for the dice game Farkle. No Flutter imports so it stays trivially
/// unit-testable and is reused by the editor, the card preview and the exporters.
///
/// Like a `game` note, all state lives as a small JSON document in the note's
/// `body` (a note of `type == 'farkle'`), so it rides the existing note
/// last-write-wins sync, JSON/zip backup and server snapshots for free. Layout:
///
/// ```json
/// {
///   "v": 1, "kind": "farkle", "target": 10000, "currentIdx": 0, "ended": false,
///   "players": [ { "id": "abc", "name": "Alice", "score": 950, "turn": 0, "rank": 1 } ]
/// }
/// ```
///
/// Turn-based: one active player (`currentIdx`) accumulates a `turn` score, then
/// **confirms** (bank into `score`) or **farkles** (bust `turn` to 0); either
/// advances to the next unfinished player. Reaching `target` assigns a finish
/// `rank` (1 = first to reach it); when everyone has finished the game `ended`.

/// Default target score, and the quick +/- presets offered by the UI.
const int kFarkleDefaultTarget = 10000;
const List<int> kFarklePosPresets = [500, 100, 50];
const List<int> kFarkleNegPresets = [-500, -100, -50];

/// One player in a farkle note. Mutable so the editor can edit in place before
/// re-encoding to the note body.
class FarklePlayer {
  FarklePlayer({
    required this.id,
    required this.name,
    this.score = 0,
    this.turnScore = 0,
    this.rank,
  });

  final String id;
  String name;

  /// Banked total.
  int score;

  /// Points accumulated in the current (unbanked) turn.
  int turnScore;

  /// Finish position (1-based) once the player reaches the target, else null.
  int? rank;

  bool get finished => rank != null;
}

/// The parsed state of a farkle note.
class FarkleState {
  FarkleState({
    required this.players,
    this.target = kFarkleDefaultTarget,
    this.currentIdx = 0,
    this.ended = false,
  });

  final List<FarklePlayer> players;
  int target;
  int currentIdx;
  bool ended;

  /// True when the note holds nothing worth keeping (drives auto-trash-on-close).
  bool get isEmpty => players.every((p) =>
      p.name.trim().isEmpty && p.score == 0 && p.turnScore == 0);

  /// The player whose turn it is, or null when there are none.
  FarklePlayer? get active =>
      (currentIdx >= 0 && currentIdx < players.length) ? players[currentIdx] : null;

  int get _nextRank =>
      players.fold(0, (m, p) => (p.rank ?? 0) > m ? p.rank! : m) + 1;

  /// Players in standings order: finished by rank ascending, then the rest by
  /// score descending. Keeps input order among equal scores.
  List<FarklePlayer> standings() {
    final finished = players.where((p) => p.finished).toList()
      ..sort((a, b) => a.rank!.compareTo(b.rank!));
    final rest = players.where((p) => !p.finished).toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return [...finished, ...rest];
  }

  // ---- transitions (mutating; guarded so stale taps are no-ops) ------------

  void addToTurn(int delta) {
    final p = active;
    if (p == null || p.finished || ended) return;
    final v = p.turnScore + delta;
    p.turnScore = v < 0 ? 0 : v;
  }

  void confirmTurn() {
    final p = active;
    if (p == null || p.finished || ended) return;
    p.score += p.turnScore;
    p.turnScore = 0;
    if (p.score >= target && p.rank == null) p.rank = _nextRank;
    _advance();
  }

  void farkle() {
    final p = active;
    if (p == null || p.finished || ended) return;
    p.turnScore = 0;
    _advance();
  }

  void _advance() {
    if (players.isEmpty || players.every((p) => p.finished)) {
      ended = true;
      return;
    }
    var i = currentIdx;
    for (var steps = 0; steps < players.length; steps++) {
      i = (i + 1) % players.length;
      if (!players[i].finished) {
        currentIdx = i;
        return;
      }
    }
    ended = true;
  }

  void addPlayer(String id) => players.add(FarklePlayer(id: id, name: ''));

  void removePlayer(String id) {
    final idx = players.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    players.removeAt(idx);
    if (players.isEmpty) {
      currentIdx = 0;
      ended = false;
      return;
    }
    if (idx < currentIdx) currentIdx--;
    if (currentIdx >= players.length) currentIdx = 0;
    if (players.every((p) => p.finished)) {
      ended = true;
    } else if (players[currentIdx].finished) {
      final ni = players.indexWhere((p) => !p.finished);
      if (ni >= 0) currentIdx = ni;
    }
  }

  void rename(String id, String name) {
    for (final p in players) {
      if (p.id == id) p.name = name;
    }
  }

  void setTarget(int t) => target = t < 1 ? 1 : t;

  /// Reset every score/turn/rank for a fresh game, keeping the players.
  void resetGame() {
    for (final p in players) {
      p.score = 0;
      p.turnScore = 0;
      p.rank = null;
    }
    currentIdx = 0;
    ended = false;
  }
}

/// Parses a farkle note [body]. Tolerant of empty/malformed input (returns an
/// empty state) so a brand-new note opens as a fresh board.
FarkleState parseFarkle(String body) {
  if (body.trim().isEmpty) return FarkleState(players: []);
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final players = <FarklePlayer>[
        for (final raw in (decoded['players'] as List?) ?? const [])
          if (raw is Map)
            FarklePlayer(
              id: raw['id']?.toString() ?? '',
              name: raw['name']?.toString() ?? '',
              score: (raw['score'] as num?)?.toInt() ?? 0,
              turnScore: (raw['turn'] as num?)?.toInt() ?? 0,
              rank: (raw['rank'] as num?)?.toInt(),
            ),
      ];
      return FarkleState(
        players: players,
        target: (decoded['target'] as num?)?.toInt() ?? kFarkleDefaultTarget,
        currentIdx: (decoded['currentIdx'] as num?)?.toInt() ?? 0,
        ended: decoded['ended'] == true,
      );
    }
  } catch (_) {/* fall through to empty */}
  return FarkleState(players: []);
}

/// Encodes [state] back into the JSON stored in the note body.
String encodeFarkle(FarkleState state) => jsonEncode({
      'v': 1,
      'kind': 'farkle',
      'target': state.target,
      'currentIdx': state.currentIdx,
      'ended': state.ended,
      'players': [
        for (final p in state.players)
          {
            'id': p.id,
            'name': p.name,
            'score': p.score,
            'turn': p.turnScore,
            if (p.rank != null) 'rank': p.rank,
          },
      ],
    });

/// Formats a score with thin-space thousands grouping (e.g. `10 000`).
String formatFarkleScore(int n) {
  final digits = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return (n < 0 ? '-' : '') + buf.toString();
}

/// The display place (1-based) for each player id: finished players keep their
/// rank; the rest are placed by score after all finished players.
Map<String, int> farklePlaces(FarkleState state) {
  final order = state.standings();
  final places = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    places[order[i].id] = i + 1;
  }
  return places;
}

/// Renders the standings as a Markdown table (for note export). Empty when no
/// players.
String farkleMarkdownTable(FarkleState state) {
  if (state.players.isEmpty) return '';
  final buf = StringBuffer();
  String cell(String s) => s.replaceAll('|', r'\|');
  buf.writeln('| # | Player | Score |');
  buf.writeln('| --- | --- | --- |');
  final order = state.standings();
  for (var i = 0; i < order.length; i++) {
    final p = order[i];
    final name = p.name.trim().isEmpty ? '—' : cell(p.name.trim());
    buf.writeln('| ${i + 1} | $name | ${formatFarkleScore(p.score)} |');
  }
  return buf.toString();
}

/// Renders the standings as plain text (for "share as text"). Empty when none.
String farklePlainText(FarkleState state) {
  if (state.players.isEmpty) return '';
  final buf = StringBuffer();
  final order = state.standings();
  for (var i = 0; i < order.length; i++) {
    final p = order[i];
    final name = p.name.trim().isEmpty ? '—' : p.name.trim();
    buf.writeln('${i + 1}. $name: ${formatFarkleScore(p.score)}');
  }
  return buf.toString().trimRight();
}
