import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/audio/domain/entity/audio_route.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/route_check.dart';

void main() {
  final s = AppLocalizationsEn();

  test('a Bluetooth headset route is ok', () {
    final check = routeReadinessCheck(s: s, route: AudioRoute.bluetoothHeadset);
    expect(check.status, RecoveryStatus.ok);
    expect(check.code, PreflightCheckCode.routeBluetooth);
  });

  test('a wired headset route is ok', () {
    final check = routeReadinessCheck(s: s, route: AudioRoute.wired);
    expect(check.status, RecoveryStatus.ok);
    expect(check.code, PreflightCheckCode.routeWired);
  });

  test(
    'the phone speaker warns but does not block — desk/dev use still has '
    'to work',
    () {
      final check = routeReadinessCheck(s: s, route: AudioRoute.builtInSpeaker);
      expect(check.status, RecoveryStatus.warn);
      expect(check.code, PreflightCheckCode.routePhoneSpeaker);
    },
  );

  test('unknown (no channel to ask, e.g. iOS) never blocks either', () {
    final check = routeReadinessCheck(s: s, route: AudioRoute.unknown);
    expect(check.status, RecoveryStatus.unknown);
    expect(check.code, PreflightCheckCode.routeUnknown);
  });
}
