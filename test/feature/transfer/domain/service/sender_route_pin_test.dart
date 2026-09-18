import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/sender_route_pin.dart';

void main() {
  final t0 = DateTime(2026, 8, 15, 9, 30);
  const hotspot = '10.122.230.245';
  const router = '192.168.8.107';
  const sender = 'f0243a6c52c7';

  group('SenderRoutePin', () {
    test('pins the first route a sender is heard on', () {
      final pin = SenderRoutePin();
      final v = pin.offer(sender, hotspot, t0);
      expect(v.decision, RouteDecision.pinned);
      expect(v.isAccepted, isTrue);
      expect(pin.pinnedFor(sender), hotspot);
    });

    test('accepts everything that keeps arriving on the pinned route', () {
      final pin = SenderRoutePin();
      pin.offer(sender, hotspot, t0);
      for (var ms = 20; ms <= 2000; ms += 20) {
        final v = pin.offer(sender, hotspot, t0.add(Duration(milliseconds: ms)));
        expect(v.decision, RouteDecision.accepted);
      }
    });

    // The whole point. The second copy is what the jitter buffer cannot tell
    // apart from a restarted stream.
    test('rejects a second route while the pinned one is delivering', () {
      final pin = SenderRoutePin();
      pin.offer(sender, hotspot, t0);
      final v = pin.offer(sender, router, t0.add(const Duration(seconds: 1)));
      expect(v.decision, RouteDecision.rejected);
      expect(v.isAccepted, isFalse);
      expect(pin.pinnedFor(sender), hotspot);
    });

    // Interleaved delivery is the realistic shape: both paths carry the same
    // stream at the same rate, so the live route keeps refreshing the pin and
    // the duplicate must never accumulate enough silence to take over.
    test('a duplicate path never wins while both are live', () {
      final pin = SenderRoutePin();
      pin.offer(sender, hotspot, t0);
      var rejected = 0;
      for (var ms = 20; ms <= 60000; ms += 20) {
        final at = t0.add(Duration(milliseconds: ms));
        expect(pin.offer(sender, hotspot, at).decision, RouteDecision.accepted);
        if (pin.offer(sender, router, at).decision == RouteDecision.rejected) {
          rejected++;
        }
      }
      expect(rejected, 3000);
      expect(pin.pinnedFor(sender), hotspot);
    });

    test('another route takes over once the pinned one passes the grace', () {
      final pin = SenderRoutePin(grace: const Duration(seconds: 6));
      pin.offer(sender, hotspot, t0);
      // Still inside the grace — rejected.
      expect(
        pin.offer(sender, router, t0.add(const Duration(seconds: 5))).decision,
        RouteDecision.rejected,
      );
      final v = pin.offer(sender, router, t0.add(const Duration(seconds: 7)));
      expect(v.decision, RouteDecision.repinned);
      expect(v.previous, hotspot);
      expect(v.previousSilence, const Duration(seconds: 7));
      expect(pin.pinnedFor(sender), router);
    });

    // A pin that could never be released would trade a bad-audio bug for a
    // no-audio one: a phone that genuinely changes network would be ignored
    // for the rest of the session.
    test('a phone that moves networks is heard again after the grace', () {
      final pin = SenderRoutePin();
      pin.offer(sender, hotspot, t0);
      var at = t0;
      for (var i = 0; i < 10; i++) {
        at = at.add(const Duration(seconds: 1));
        pin.offer(sender, router, at);
      }
      expect(pin.pinnedFor(sender), router);
      expect(pin.offer(sender, router, at).decision, RouteDecision.accepted);
    });

    test('senders are pinned independently of one another', () {
      final pin = SenderRoutePin();
      pin.offer('a', hotspot, t0);
      pin.offer('b', router, t0);
      expect(pin.pinnedFor('a'), hotspot);
      expect(pin.pinnedFor('b'), router);
      // b on the router does not disturb a on the hotspot: a channel spanning
      // two networks keeps working, which is why this is per sender.
      expect(
        pin.offer('b', router, t0.add(const Duration(seconds: 1))).decision,
        RouteDecision.accepted,
      );
      expect(
        pin.offer('a', hotspot, t0.add(const Duration(seconds: 1))).decision,
        RouteDecision.accepted,
      );
      expect(pin.pinnedAddresses, unorderedEquals([hotspot, router]));
    });

    test('clear drops every pin so a new session starts free', () {
      final pin = SenderRoutePin();
      pin.offer(sender, hotspot, t0);
      pin.clear();
      expect(pin.pinnedFor(sender), isNull);
      expect(pin.pinnedAddresses, isEmpty);
      expect(
        pin.offer(sender, router, t0.add(const Duration(seconds: 1))).decision,
        RouteDecision.pinned,
      );
    });

    test('forget releases one sender without touching the others', () {
      final pin = SenderRoutePin();
      pin.offer('a', hotspot, t0);
      pin.offer('b', router, t0);
      pin.forget('a');
      expect(pin.pinnedFor('a'), isNull);
      expect(pin.pinnedFor('b'), router);
    });
  });
}
