import 'package:flutter_test/flutter_test.dart';
import 'package:noteesek/data/version_check.dart';

void main() {
  group('VersionStatus.mismatch', () {
    test('true when both known and differ', () {
      expect(
        const VersionStatus(appVersion: '1.5.0', serverVersion: '1.4.7')
            .mismatch,
        isTrue,
      );
    });

    test('false when equal', () {
      expect(
        const VersionStatus(appVersion: '1.5.0', serverVersion: '1.5.0')
            .mismatch,
        isFalse,
      );
    });

    test('false when either side is unknown', () {
      expect(const VersionStatus(appVersion: '1.5.0').mismatch, isFalse);
      expect(const VersionStatus(serverVersion: '1.5.0').mismatch, isFalse);
      expect(const VersionStatus().mismatch, isFalse);
    });

    test('false when either side is empty', () {
      expect(
        const VersionStatus(appVersion: '1.5.0', serverVersion: '').mismatch,
        isFalse,
      );
    });
  });
}
