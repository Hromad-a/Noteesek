import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/features/notes/farkle_model.dart';

FarkleState _game(int players, {int target = 1000}) {
  final s = FarkleState(players: [], target: target);
  for (var i = 0; i < players; i++) {
    s.addPlayer('p$i');
    s.players[i].name = 'P$i';
  }
  return s;
}

void main() {
  test('addToTurn accumulates and clamps at zero', () {
    final s = _game(2);
    s.addToTurn(500);
    s.addToTurn(100);
    expect(s.active!.turnScore, 600);
    s.addToTurn(-1000); // clamps, not negative
    expect(s.active!.turnScore, 0);
  });

  test('addToTurn only affects the active player', () {
    final s = _game(2);
    s.addToTurn(300);
    expect(s.players[0].turnScore, 300);
    expect(s.players[1].turnScore, 0);
  });

  test('confirm banks the turn and advances to the next player', () {
    final s = _game(2);
    s.addToTurn(400);
    s.confirmTurn();
    expect(s.players[0].score, 400);
    expect(s.players[0].turnScore, 0);
    expect(s.currentIdx, 1); // advanced
  });

  test('farkle busts the turn and advances', () {
    final s = _game(2);
    s.addToTurn(750);
    s.farkle();
    expect(s.players[0].score, 0);
    expect(s.players[0].turnScore, 0);
    expect(s.currentIdx, 1);
  });

  test('reaching target assigns finish ranks in order and skips finished', () {
    final s = _game(3, target: 1000);
    // p0 reaches target first.
    s.addToTurn(1000);
    s.confirmTurn();
    expect(s.players[0].rank, 1);
    expect(s.players[0].finished, isTrue);
    expect(s.currentIdx, 1); // p1's turn

    // p1 does not reach; p2 does -> rank 2.
    s.addToTurn(200);
    s.confirmTurn(); // p1 banks 200, advance to p2
    expect(s.currentIdx, 2);
    s.addToTurn(1000);
    s.confirmTurn(); // p2 finishes rank 2, advance -> skips finished p0, back to p1
    expect(s.players[2].rank, 2);
    expect(s.currentIdx, 1);
    expect(s.ended, isFalse);
  });

  test('game ends when all players have finished', () {
    final s = _game(2, target: 100);
    s.addToTurn(100);
    s.confirmTurn(); // p0 finishes, -> p1
    s.addToTurn(100);
    s.confirmTurn(); // p1 finishes -> all done
    expect(s.ended, isTrue);
    expect(s.players.every((p) => p.finished), isTrue);
  });

  test('standings order finished-by-rank then rest-by-score', () {
    final s = _game(3, target: 100000);
    s.players[0].score = 300;
    s.players[1].score = 900;
    s.players[1].rank = 1; // finished first
    s.players[2].score = 500;
    final order = s.standings().map((p) => p.id).toList();
    expect(order, ['p1', 'p2', 'p0']); // rank1, then 500, then 300
  });

  test('removePlayer keeps currentIdx valid', () {
    final s = _game(3);
    s.currentIdx = 2;
    s.removePlayer('p0'); // indices shift down
    expect(s.players.length, 2);
    expect(s.currentIdx, 1);
    expect(s.active, isNotNull);
  });

  test('resetGame clears scores, ranks and ended', () {
    final s = _game(2, target: 100);
    s.addToTurn(100);
    s.confirmTurn();
    s.addToTurn(100);
    s.confirmTurn();
    expect(s.ended, isTrue);
    s.resetGame();
    expect(s.ended, isFalse);
    expect(s.currentIdx, 0);
    expect(s.players.every((p) => p.score == 0 && p.rank == null), isTrue);
  });

  test('parse/encode round-trips', () {
    final s = _game(2, target: 5000);
    s.addToTurn(450);
    s.confirmTurn();
    s.players[1].name = 'Bob';
    final round = parseFarkle(encodeFarkle(s));
    expect(round.target, 5000);
    expect(round.currentIdx, s.currentIdx);
    expect(round.players.map((p) => p.name).toList(), ['P0', 'Bob']);
    expect(round.players[0].score, 450);
  });

  test('parseFarkle tolerates empty/garbage', () {
    expect(parseFarkle('').players, isEmpty);
    expect(parseFarkle('not json').players, isEmpty);
    expect(parseFarkle('').target, kFarkleDefaultTarget);
  });

  test('isEmpty only for blank/unscored players', () {
    expect(FarkleState(players: []).isEmpty, isTrue);
    final s = _game(1)..players[0].name = '';
    expect(s.isEmpty, isTrue);
    s.players[0].score = 50;
    expect(s.isEmpty, isFalse);
  });

  test('formatFarkleScore groups thousands', () {
    final nb = String.fromCharCode(0x202F); // narrow no-break space separator
    expect(formatFarkleScore(0), '0');
    expect(formatFarkleScore(950), '950');
    expect(formatFarkleScore(10000), '10${nb}000');
    expect(formatFarkleScore(-1500), '-1${nb}500');
  });
}
