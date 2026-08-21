import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/service/preflight_checks.dart';

RecoveryCheck _row(RecoveryStatus status) =>
    RecoveryCheck(label: 'x', detail: 'x', status: status);

void main() {
  group('hasBlockingFailure', () {
    test('false when every row is ok/warn/unknown', () {
      expect(
        hasBlockingFailure([
          _row(RecoveryStatus.ok),
          _row(RecoveryStatus.warn),
          _row(RecoveryStatus.unknown),
        ]),
        isFalse,
      );
    });

    test('true the moment one row is bad', () {
      expect(
        hasBlockingFailure([_row(RecoveryStatus.ok), _row(RecoveryStatus.bad)]),
        isTrue,
      );
    });
  });

  group('hasOnlyWarnings', () {
    test('true when the worst row is a warning', () {
      expect(
        hasOnlyWarnings([_row(RecoveryStatus.ok), _row(RecoveryStatus.warn)]),
        isTrue,
      );
    });

    test('false when nothing is wrong', () {
      expect(hasOnlyWarnings([_row(RecoveryStatus.ok)]), isFalse);
    });

    test('false once something is a hard failure, even alongside a warning', () {
      expect(
        hasOnlyWarnings([_row(RecoveryStatus.warn), _row(RecoveryStatus.bad)]),
        isFalse,
      );
    });
  });
}
