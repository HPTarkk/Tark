import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/background_readiness_check.dart';

void main() {
  final s = AppLocalizationsEn();
  Future<void> noop() async {}

  RecoveryCheck check({
    bool notificationRequired = false,
    bool notificationGranted = true,
    bool batteryExempt = true,
    bool isMiui = false,
  }) => backgroundReadinessCheck(
    s: s,
    notificationRequired: notificationRequired,
    notificationGranted: notificationGranted,
    batteryExempt: batteryExempt,
    isMiui: isMiui,
    requestNotification: noop,
    requestBatteryExemption: noop,
    openAutoStartSettings: noop,
  );

  test('everything fine (or not required) is ok, no actions', () {
    final c = check();
    expect(c.status, RecoveryStatus.ok);
    expect(c.code, PreflightCheckCode.backgroundOk);
    expect(c.actions, isEmpty);
  });

  test(
    'below SDK 33, a denied notification permission does not even ask — '
    'nothing was required',
    () {
      final c = check(notificationRequired: false, notificationGranted: false);
      expect(c.status, RecoveryStatus.ok);
    },
  );

  test(
    'battery restriction warns, never blocks — an OS setting the app '
    'cannot force is a warning with a fix, not a wall',
    () {
      final c = check(batteryExempt: false);
      expect(c.status, RecoveryStatus.warn);
      expect(c.code, PreflightCheckCode.backgroundBatteryRestricted);
      expect(c.actions, hasLength(1));
      expect(c.actions.single.isPrimary, isTrue);
    },
  );

  test(
    'MIUI adds the Autostart action alongside the battery fix, not as a '
    'separate failure — MIUI alone with the exemption already granted is '
    'not flagged',
    () {
      final exempt = check(batteryExempt: true, isMiui: true);
      expect(exempt.status, RecoveryStatus.ok);

      final restricted = check(batteryExempt: false, isMiui: true);
      expect(restricted.status, RecoveryStatus.warn);
      expect(restricted.actions, hasLength(2));
    },
  );

  test('a denied notification permission alone warns with its own action', () {
    final c = check(notificationRequired: true, notificationGranted: false);
    expect(c.status, RecoveryStatus.warn);
    expect(c.code, PreflightCheckCode.backgroundNotificationDenied);
    expect(c.actions, hasLength(1));
    expect(c.actions.single.isPrimary, isTrue);
  });

  test(
    'battery restriction outranks notification for the row\'s own detail/code '
    '(worst-of), but both fixes are still offered',
    () {
      final c = check(
        notificationRequired: true,
        notificationGranted: false,
        batteryExempt: false,
        isMiui: true,
      );
      expect(c.status, RecoveryStatus.warn);
      expect(c.code, PreflightCheckCode.backgroundBatteryRestricted);
      expect(c.actions, hasLength(3));
      expect(c.actions.first.isPrimary, isTrue);
      // The notification fix is still offered, just not the primary action.
      expect(c.actions.last.isPrimary, isFalse);
    },
  );
}
