import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/domain/entity/preflight_check_code.dart';
import 'package:tark/feature/preflight/domain/service/transport_readiness_check.dart';
import 'package:tark/feature/transfer/domain/entity/channel_intent.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/transport_advisor.dart';

void main() {
  final s = AppLocalizationsEn();

  ChannelPlan planFor({required bool hasWifi, required bool bluetooth}) =>
      TransportAdvisor.plan(
        ChannelIntent.create,
        LinkConditions(
          hasWifi: hasWifi,
          canHostHotspot: false,
          canJoinHotspot: false,
          bluetoothSupported: bluetooth,
        ),
      );

  test(
    'a blocked plan (pinned Wi-Fi, no network) is a hard failure — the '
    'issue\'s own "no usable local network path" case',
    () {
      final blocked = TransportAdvisor.plan(
        ChannelIntent.create,
        const LinkConditions(
          hasWifi: false,
          canHostHotspot: false,
          canJoinHotspot: false,
          bluetoothSupported: false,
          pinned: TransferMode.wifi,
        ),
      );
      expect(blocked.blocked, isTrue, reason: 'sanity-check the fixture');

      final check = transportReadinessCheck(s: s, plan: blocked);
      expect(check.status, RecoveryStatus.bad);
      expect(check.code, PreflightCheckCode.transportBlocked);
    },
  );

  test(
    'no connection attempted yet is unknown, never a failure — "local '
    'transport ready" and "peer verified" are different questions',
    () {
      final plan = planFor(hasWifi: true, bluetooth: false);
      final check = transportReadinessCheck(s: s, plan: plan);
      expect(check.status, RecoveryStatus.unknown);
      expect(check.code, PreflightCheckCode.transportNotAttempted);
    },
  );

  group('post-connect, a live ConnectionHealth is known', () {
    final plan = planFor(hasWifi: true, bluetooth: false);

    test('healthy is ok', () {
      final check = transportReadinessCheck(
        s: s,
        plan: plan,
        liveHealth: const ConnectionHealth.healthy(),
      );
      expect(check.status, RecoveryStatus.ok);
      expect(check.code, PreflightCheckCode.transportReady);
    });

    test('degraded (quietly self-healing) is still ok, not a warning', () {
      final check = transportReadinessCheck(
        s: s,
        plan: plan,
        liveHealth: const ConnectionHealth.degraded(),
      );
      expect(check.status, RecoveryStatus.ok);
    });

    test('reconnecting warns but does not block', () {
      final check = transportReadinessCheck(
        s: s,
        plan: plan,
        liveHealth: const ConnectionHealth.reconnecting(),
      );
      expect(check.status, RecoveryStatus.warn);
      expect(check.code, PreflightCheckCode.transportDegraded);
    });

    test('renegotiating warns but does not block', () {
      final check = transportReadinessCheck(
        s: s,
        plan: plan,
        liveHealth: const ConnectionHealth.renegotiating(),
      );
      expect(check.status, RecoveryStatus.warn);
    });

    test('down (nothing further attempted automatically) is a hard failure', () {
      final check = transportReadinessCheck(
        s: s,
        plan: plan,
        liveHealth: const ConnectionHealth.down(),
      );
      expect(check.status, RecoveryStatus.bad);
      expect(check.code, PreflightCheckCode.transportDown);
    });
  });
}
