import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/data/mic_probe.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/mic_check.dart';

void main() {
  final s = AppLocalizationsEn();
  Future<void> noRetry() async {}

  test('permission denied is a hard failure with a retry action', () {
    final check = micCheck(
      s: s,
      outcome: MicProbeOutcome.permissionDenied,
      retry: noRetry,
    );
    expect(check.status, RecoveryStatus.bad);
    expect(check.code, PreflightCheckCode.micPermissionDenied);
    expect(check.actions, isNotEmpty);
  });

  test(
    'started-but-no-frames is a hard failure — never fake green on a '
    'permission flag alone',
    () {
      final check = micCheck(
        s: s,
        outcome: MicProbeOutcome.noFrames,
        retry: noRetry,
      );
      expect(check.status, RecoveryStatus.bad);
      expect(check.code, PreflightCheckCode.micNoFrames);
    },
  );

  test('a delivered frame is ok with no actions offered', () {
    final check = micCheck(s: s, outcome: MicProbeOutcome.ok, retry: noRetry);
    expect(check.status, RecoveryStatus.ok);
    expect(check.code, PreflightCheckCode.micOk);
    expect(check.actions, isEmpty);
  });

  test('remediation action updates check state — the retry callback runs', () async {
    var ranCount = 0;
    final check = micCheck(
      s: s,
      outcome: MicProbeOutcome.noFrames,
      retry: () async => ranCount++,
    );
    await check.actions.first.run();
    expect(ranCount, 1);
  });
}
