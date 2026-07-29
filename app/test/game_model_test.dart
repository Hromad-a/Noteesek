import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/features/notes/game_model.dart';

void main() {
  group('parseGame', () {
    test('empty body is an empty game', () {
      expect(parseGame('').players, isEmpty);
      expect(parseGame('   ').players, isEmpty);
    });

    test('malformed body falls back to empty', () {
      expect(parseGame('not json').players, isEmpty);
      expect(parseGame('{"players": "nope"}').players, isEmpty);
    });

    test('parses players, names and scores (ints and doubles)', () {
      final g = parseGame(
          '{"v":1,"players":[{"id":"a","name":"Alice","scores":[10,5.5]},'
          '{"id":"b","name":"Bob","scores":[8]}]}');
      expect(g.players.map((p) => p.name), ['Alice', 'Bob']);
      expect(g.players[0].scores, [10.0, 5.5]);
      expect(g.players[1].scores, [8.0]);
    });
  });

  test('encode/parse round-trips and keeps whole numbers as ints', () {
    final g = GameState(players: [
      GamePlayer(id: 'a', name: 'Alice', scores: [10, 5.5]),
      GamePlayer(id: 'b', name: 'Bob', scores: [8, 0]),
    ]);
    final encoded = encodeGame(g);
    expect(encoded.contains('10.0'), isFalse); // whole numbers compacted
    final back = parseGame(encoded);
    expect(back.players[0].scores, [10.0, 5.5]);
    expect(back.players[1].scores, [8.0, 0.0]);
  });

  test('total and scoreAt (out-of-range round counts as 0)', () {
    final p = GamePlayer(id: 'a', name: 'A', scores: [3, 4, -1]);
    final g = GameState(players: [p]);
    expect(p.total, 6.0);
    expect(g.scoreAt(p, 0), 3.0);
    expect(g.scoreAt(p, 9), 0.0);
    expect(g.rounds, 3);
  });

  test('rounds is the longest player score list', () {
    final g = GameState(players: [
      GamePlayer(id: 'a', name: 'A', scores: [1, 2, 3]),
      GamePlayer(id: 'b', name: 'B', scores: [1]),
    ]);
    expect(g.rounds, 3);
  });

  group('ranksByTotal', () {
    test('highest total is rank 1, players keep their order elsewhere', () {
      final g = GameState(players: [
        GamePlayer(id: 'a', name: 'A', scores: [5]), // total 5 → rank 2
        GamePlayer(id: 'b', name: 'B', scores: [9]), // total 9 → rank 1
        GamePlayer(id: 'c', name: 'C', scores: [1]), // total 1 → rank 3
      ]);
      final r = g.ranksByTotal();
      expect(r['b'], 1);
      expect(r['a'], 2);
      expect(r['c'], 3);
    });

    test('ties share a rank', () {
      final g = GameState(players: [
        GamePlayer(id: 'a', name: 'A', scores: [5]),
        GamePlayer(id: 'b', name: 'B', scores: [5]),
        GamePlayer(id: 'c', name: 'C', scores: [1]),
      ]);
      final r = g.ranksByTotal();
      expect(r['a'], 1);
      expect(r['b'], 1);
      expect(r['c'], 3); // rank 2 is skipped after the tie
    });
  });

  test('isEmpty is true only for blank/unscored players', () {
    expect(GameState(players: []).isEmpty, isTrue);
    expect(
        GameState(players: [GamePlayer(id: 'a', name: '', scores: [0, 0])])
            .isEmpty,
        isTrue);
    expect(
        GameState(players: [GamePlayer(id: 'a', name: 'A', scores: [])])
            .isEmpty,
        isFalse);
    expect(
        GameState(players: [GamePlayer(id: 'a', name: '', scores: [3])])
            .isEmpty,
        isFalse);
  });

  group('formatGameScore', () {
    test('whole numbers have no decimals', () {
      expect(formatGameScore(10), '10');
      expect(formatGameScore(-2), '-2');
      expect(formatGameScore(0), '0');
    });
    test('fractions trim trailing zeros', () {
      expect(formatGameScore(5.5), '5.5');
      expect(formatGameScore(-2.25), '-2.25');
    });
  });

  test('gameMarkdownTable renders rounds, players and a totals row', () {
    final g = GameState(players: [
      GamePlayer(id: 'a', name: 'Alice', scores: [10, 5]),
      GamePlayer(id: 'b', name: 'Bob', scores: [8, 8]),
    ]);
    final md = gameMarkdownTable(g);
    expect(md, contains('| Round | Alice | Bob |'));
    expect(md, contains('| 1 | 10 | 8 |'));
    expect(md, contains('| 2 | 5 | 8 |'));
    expect(md, contains('| Total | 15 | 16 |'));
  });

  test('gamePlainText lists players by total, highest first', () {
    final g = GameState(players: [
      GamePlayer(id: 'a', name: 'Alice', scores: [10]),
      GamePlayer(id: 'b', name: 'Bob', scores: [16]),
    ]);
    expect(gamePlainText(g), 'Bob: 16\nAlice: 10');
  });

  test('empty game renders empty export strings', () {
    final g = GameState(players: []);
    expect(gameMarkdownTable(g), '');
    expect(gamePlainText(g), '');
  });
}
