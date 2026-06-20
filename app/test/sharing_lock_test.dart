import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/local/ids.dart';
import 'package:noteesek/features/notes/sharing_service.dart';

void main() {
  test('lockIsFresh: empty / unparseable ⇒ not held', () {
    expect(lockIsFresh(''), isFalse);
    expect(lockIsFresh('   '), isFalse);
    expect(lockIsFresh('not-a-date'), isFalse);
  });

  test('lockIsFresh: a just-set lock is held', () {
    expect(lockIsFresh(pbNow()), isTrue);
  });

  test('lockIsFresh: a lock older than the expiry window is stale', () {
    final old = DateTime.now()
        .toUtc()
        .subtract(kLockExpiry + const Duration(seconds: 30))
        .toIso8601String();
    expect(lockIsFresh(old), isFalse);
  });

  test('sharedWithIds decodes the JSON id array', () {
    expect(sharedWithIds('[]'), isEmpty);
    expect(sharedWithIds('["a","b"]'), ['a', 'b']);
    expect(sharedWithIds(''), isEmpty);
  });
}
