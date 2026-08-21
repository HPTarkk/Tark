import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/diagnostics_readiness_check.dart';

void main() {
  final s = AppLocalizationsEn();

  test('enabled and persisting is ok', () {
    final check = diagnosticsReadinessCheck(
      s: s,
      isEnabled: true,
      isPersisting: true,
    );
    expect(check.status, RecoveryStatus.ok);
    expect(check.code, PreflightCheckCode.diagnosticsOk);
  });

  test(
    'enabled but memory-only warns — an export still works off the ring, '
    'it just would not survive a kill',
    () {
      final check = diagnosticsReadinessCheck(
        s: s,
        isEnabled: true,
        isPersisting: false,
      );
      expect(check.status, RecoveryStatus.warn);
      expect(check.code, PreflightCheckCode.diagnosticsMemoryOnly);
    },
  );

  test(
    'disabled is unknown, never bad — not something the user can act on '
    'mid-Preflight',
    () {
      final check = diagnosticsReadinessCheck(
        s: s,
        isEnabled: false,
        isPersisting: false,
      );
      expect(check.status, RecoveryStatus.unknown);
      expect(check.code, PreflightCheckCode.diagnosticsDisabled);
    },
  );
}
