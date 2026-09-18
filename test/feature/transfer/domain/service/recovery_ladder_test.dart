import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/service/recovery_ladder.dart';

void main() {
  const delay = Duration(seconds: 4);

  ConnectionHealthStatus rungAfter(int attempts, {Duration? wait = delay}) {
    final ladder = RecoveryLadder();
    for (var i = 0; i < attempts; i++) {
      ladder.escalate();
    }
    return ladder.rung(wait).status;
  }

  group('RecoveryLadder', () {
    // The reason the ladder exists: a dip that heals on the first retry must
    // never reach the banner or the link-lost sound.
    test('the first attempt is served quietly', () {
      expect(rungAfter(1), ConnectionHealthStatus.degraded);
    });

    test('a failure that outlives the quiet rung becomes news', () {
      expect(rungAfter(2), ConnectionHealthStatus.reconnecting);
      expect(rungAfter(3), ConnectionHealthStatus.reconnecting);
    });

    test('rebinding that keeps failing escalates to renegotiating', () {
      expect(rungAfter(4), ConnectionHealthStatus.renegotiating);
      expect(rungAfter(40), ConnectionHealthStatus.renegotiating);
    });

    // The ladder never reports down on its own: that state means "nothing
    // further will be attempted without the user", which is the caller's
    // decision (auto-reconnect off), not a rung.
    test('never reports down', () {
      for (var i = 0; i <= 20; i++) {
        expect(rungAfter(i), isNot(ConnectionHealthStatus.down));
      }
    });

    test('renegotiation is asked for exactly past the rebind rungs', () {
      final ladder = RecoveryLadder();
      expect(ladder.shouldRenegotiate, isFalse);
      for (var i = 0; i < 3; i++) {
        ladder.escalate();
        expect(ladder.shouldRenegotiate, isFalse, reason: 'attempt ${i + 1}');
      }
      ladder.escalate();
      expect(ladder.shouldRenegotiate, isTrue);
    });

    test('traffic flowing again drops back to the quiet rung', () {
      final ladder = RecoveryLadder();
      for (var i = 0; i < 10; i++) {
        ladder.escalate();
      }
      expect(ladder.rung(delay).status, ConnectionHealthStatus.renegotiating);

      ladder.reset();

      expect(ladder.attempts, 0);
      expect(ladder.shouldRenegotiate, isFalse);
      // The next hiccup is a fresh one and gets the quiet treatment again,
      // rather than inheriting the escalation of a run that already healed.
      ladder.escalate();
      expect(ladder.rung(delay).status, ConnectionHealthStatus.degraded);
    });

    test('a schedule is carried so the banner can count down', () {
      final ladder = RecoveryLadder()
        ..escalate()
        ..escalate();
      final health = ladder.rung(delay);
      expect(health.status, ConnectionHealthStatus.reconnecting);
      expect(health.retryDelay, delay);
      expect(health.nextRetryAt, isNotNull);
    });

    // Passing null means "the attempt is running now" — it drops the countdown
    // without moving the rung, so an attempt about to renegotiate does not
    // flash back through reconnecting on its way there.
    test('dropping the countdown leaves the rung where it was', () {
      final ladder = RecoveryLadder();
      for (var i = 0; i < 5; i++) {
        ladder.escalate();
      }
      final health = ladder.rung(null);
      expect(health.status, ConnectionHealthStatus.renegotiating);
      expect(health.nextRetryAt, isNull);
      expect(health.retryDelay, isNull);
    });
  });

  group('ConnectionHealth', () {
    test('degraded is live, so nothing user-facing fires for it', () {
      expect(const ConnectionHealth.degraded().isLive, isTrue);
      expect(const ConnectionHealth.healthy().isLive, isTrue);
      expect(const ConnectionHealth.reconnecting().isLive, isFalse);
      expect(const ConnectionHealth.renegotiating().isLive, isFalse);
      expect(const ConnectionHealth.down().isLive, isFalse);
    });

    // isHealthy stays strict: only the transport's own repair logic uses it,
    // and a degraded link genuinely is not healthy.
    test('degraded is not healthy', () {
      expect(const ConnectionHealth.degraded().isHealthy, isFalse);
      expect(const ConnectionHealth.healthy().isHealthy, isTrue);
    });

    test('only down needs the user', () {
      expect(const ConnectionHealth.degraded().isRecoverable, isTrue);
      expect(const ConnectionHealth.reconnecting().isRecoverable, isTrue);
      expect(const ConnectionHealth.renegotiating().isRecoverable, isTrue);
      expect(const ConnectionHealth.down().isRecoverable, isFalse);
    });
  });
}
