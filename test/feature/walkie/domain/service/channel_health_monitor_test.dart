import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/walkie/domain/service/channel_health_monitor.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('micDelivering', () {
    test('has no opinion before the channel is ready', () {
      final m = ChannelHealthMonitor();
      expect(
        m.micDelivering(now: at(60), isReady: true, hasPermission: true),
        isNull,
      );
      m.markReady(t0);
      expect(
        m.micDelivering(now: at(60), isReady: false, hasPermission: true),
        isNull,
      );
      expect(
        m.micDelivering(now: at(60), isReady: true, hasPermission: false),
        isNull,
      );
    });

    test('reports a dead mic only after six silent seconds', () {
      final m = ChannelHealthMonitor()..markReady(t0);
      expect(
        m.micDelivering(now: at(5), isReady: true, hasPermission: true),
        isTrue,
      );
      expect(
        m.micDelivering(now: at(6), isReady: true, hasPermission: true),
        isFalse,
      );
      m.noteFrame(at(6));
      expect(
        m.micDelivering(now: at(7), isReady: true, hasPermission: true),
        isTrue,
      );
    });
  });

  group('networkMissing', () {
    bool? check(ChannelHealthMonitor m, int s, {String id = ''}) =>
        m.networkMissing(
          now: at(s),
          needsAddress: true,
          isReady: true,
          localId: id,
        );

    test('waits out the grace period, then reports', () {
      final m = ChannelHealthMonitor();
      expect(check(m, 0), isNull);
      expect(check(m, 4), isNull);
      expect(check(m, 5), isTrue);
    });

    test('an address, or a transport without one, clears it and the clock', () {
      final m = ChannelHealthMonitor();
      expect(check(m, 0, id: '0.0.0.0'), isNull);
      expect(check(m, 3, id: '10.0.0.2'), isFalse);
      // The gap starts over rather than counting from the first one.
      expect(check(m, 6), isNull);
      expect(
        m.networkMissing(
          now: at(60),
          needsAddress: false,
          isReady: true,
          localId: '',
        ),
        isFalse,
      );
    });
  });

  group('audibility', () {
    AudibilityVerdict check(
      ChannelHealthMonitor m,
      int s, {
      bool peers = true,
    }) => m.audibility(now: at(s), isReady: true, hasPeers: peers);

    test('a channel nobody has confirmed yet is still forming', () {
      final m = ChannelHealthMonitor();
      expect(check(m, 60), AudibilityVerdict.unchanged);
    });

    test('warns seven seconds after the last confirmation', () {
      final m = ChannelHealthMonitor()..noteHeardByPeer(t0);
      expect(check(m, 6), AudibilityVerdict.unchanged);
      expect(check(m, 7), AudibilityVerdict.unheard);
      m.noteHeardByPeer(at(8));
      expect(check(m, 9), AudibilityVerdict.unchanged);
    });

    test('a resume or repair restarts the stretch', () {
      final m = ChannelHealthMonitor()..noteHeardByPeer(t0);
      m.restartUnheardClock(at(30));
      expect(check(m, 36), AudibilityVerdict.unchanged);
      expect(check(m, 37), AudibilityVerdict.unheard);
    });

    test('an empty channel clears the warning and forgets the last peer', () {
      final m = ChannelHealthMonitor()..noteHeardByPeer(t0);
      expect(check(m, 60, peers: false), AudibilityVerdict.clear);
      // Someone joins much later: not graded against the old confirmation.
      expect(check(m, 120), AudibilityVerdict.unchanged);
    });
  });

  group('alone', () {
    test('only after twenty empty seconds of an open channel', () {
      final m = ChannelHealthMonitor();
      expect(m.alone(now: at(60), hasPeers: false), isNull);
      m.markReady(t0);
      expect(m.alone(now: at(19), hasPeers: false), isFalse);
      expect(m.alone(now: at(20), hasPeers: false), isTrue);
      expect(m.alone(now: at(20), hasPeers: true), isFalse);
    });

    test('reset forgets the session', () {
      final m = ChannelHealthMonitor()..markReady(t0);
      m.reset();
      expect(m.readyAt, isNull);
      expect(m.alone(now: at(60), hasPeers: false), isNull);
    });
  });
}
