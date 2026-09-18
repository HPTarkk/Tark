import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/shared_music_readiness_check.dart';

void main() {
  final s = AppLocalizationsEn();

  test('supported reports ok', () {
    final check = sharedMusicReadinessCheck(s: s, isSupported: true);
    expect(check.status, RecoveryStatus.ok);
    expect(check.code, PreflightCheckCode.sharedMusicAvailable);
  });

  test(
    'unsupported is unknown, not a failure — Shared Music must never '
    'block voice Preflight',
    () {
      final check = sharedMusicReadinessCheck(s: s, isSupported: false);
      expect(check.status, RecoveryStatus.unknown);
      expect(check.code, PreflightCheckCode.sharedMusicUnavailable);
    },
  );
}
