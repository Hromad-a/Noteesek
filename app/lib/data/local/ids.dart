import 'dart:math';

const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
final _rng = Random.secure();

/// Generates a PocketBase-compatible record id (15 lowercase alphanumerics).
/// Ids are settable on create, so a record made offline keeps this id once
/// pushed — no remapping needed during sync.
String newPbId() {
  final b = StringBuffer();
  for (var i = 0; i < 15; i++) {
    b.write(_alphabet[_rng.nextInt(_alphabet.length)]);
  }
  return b.toString();
}

/// Current UTC time formatted exactly like PocketBase's `updated`/`created`
/// (e.g. "2026-06-05 00:14:58.581Z"). This format sorts lexicographically in
/// chronological order, which the last-write-wins sync relies on.
String pbNow() {
  final n = DateTime.now().toUtc();
  String p2(int v) => v.toString().padLeft(2, '0');
  String p3(int v) => v.toString().padLeft(3, '0');
  return '${n.year}-${p2(n.month)}-${p2(n.day)} '
      '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}.${p3(n.millisecond)}Z';
}
