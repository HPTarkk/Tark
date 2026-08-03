import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/analytics/analytics.dart';
import 'package:tark/core/analytics/analytics_event.dart';
import 'package:tark/core/analytics/pairing_attempt.dart';

/// Records what was tracked so the tests can assert on the token sequence —
/// the whole point of [PairingAttempt] is which events come out, in what
/// order, and how many.
class _RecordingAnalytics implements Analytics {
  final events = <AnalyticsEvent>[];

  List<String> get tokens => events.map((e) => e.token).toList();

  @override
  Future<void> start() async {}

  @override
  void track(AnalyticsEvent event) => events.add(event);

  @override
  Future<void> setEnabled(bool enabled) async {}
}

void main() {
  late _RecordingAnalytics analytics;
  late PairingAttempt attempt;

  setUp(() {
    analytics = _RecordingAnalytics();
    attempt = PairingAttempt(
      analytics,
      transport: AnalyticsTransport.bluetooth,
    );
  });

  test('a successful attempt reports started then connected', () {
    attempt.start(PairRole.host);
    attempt.connected();

    expect(analytics.tokens, [
      AnalyticsTokens.pairStarted,
      AnalyticsTokens.pairConnected,
    ]);
  });

  test('the first outcome wins — a later failure is dropped', () {
    attempt.start(PairRole.joiner);
    attempt.connected();
    // Bluetooth's connection stream is a broadcast stream that can re-emit,
    // and backToRoleSelection() reports a cancellation unconditionally. Every
    // such straggler has to be ignored or the funnel double-counts.
    attempt.failed(PairStage.dial, PairFailure.dialRefused);
    attempt.connected();

    expect(analytics.tokens, [
      AnalyticsTokens.pairStarted,
      AnalyticsTokens.pairConnected,
    ]);
  });

  test('a specific failure beats the generic cancellation behind it', () {
    attempt.start(PairRole.host);
    attempt.failed(PairStage.apSetup, PairFailure.apNeverUp);
    attempt.failed(PairStage.discover, PairFailure.userCancelled);

    expect(analytics.events.length, 2);
    expect(analytics.events.last.attributes['reason'], 'ap_never_up');
  });

  test('outcomes outside an open attempt report nothing', () {
    attempt.connected();
    attempt.failed(PairStage.dial, PairFailure.dialRefused);

    expect(analytics.events, isEmpty);
  });

  test('restarting an open attempt does not start a second one', () {
    attempt.start(PairRole.joiner);
    attempt.start(PairRole.joiner);
    attempt.connected();

    expect(analytics.tokens, [
      AnalyticsTokens.pairStarted,
      AnalyticsTokens.pairConnected,
    ]);
  });

  test('a new attempt can start after the previous one closed', () {
    attempt.start(PairRole.joiner);
    attempt.failed(PairStage.dial, PairFailure.dialRefused);
    attempt.start(PairRole.host);
    attempt.connected();

    expect(analytics.tokens, [
      AnalyticsTokens.pairStarted,
      AnalyticsTokens.pairFailed,
      AnalyticsTokens.pairStarted,
      AnalyticsTokens.pairConnected,
    ]);
    expect(analytics.events.last.attributes['role'], 'host');
  });

  test('abandon closes the attempt without reporting an outcome', () {
    attempt.start(PairRole.joiner);
    attempt.abandon();
    attempt.failed(PairStage.dial, PairFailure.dialRefused);

    expect(analytics.tokens, [AnalyticsTokens.pairStarted]);
    expect(attempt.isOpen, isFalse);
  });

  test('every attribute value is bucketed, never raw', () {
    attempt.start(PairRole.host);
    attempt.connected();

    final connected = analytics.events.last;
    expect(connected.attributes['transport'], 'bt');
    expect(connected.attributes['role'], 'host');
    // Real elapsed time, but it must arrive as a bucket label.
    expect(connected.attributes['secs'], '0_5');
  });

  group('buckets', () {
    test('connect time', () {
      expect(AnalyticsBuckets.connectSeconds(Duration.zero), '0_5');
      expect(AnalyticsBuckets.connectSeconds(const Duration(seconds: 5)), '5_15');
      expect(
        AnalyticsBuckets.connectSeconds(const Duration(seconds: 44)),
        '15_45',
      );
      expect(
        AnalyticsBuckets.connectSeconds(const Duration(minutes: 2)),
        '45_plus',
      );
    });

    test('session duration', () {
      expect(AnalyticsBuckets.sessionDuration(const Duration(seconds: 29)), '0_30s');
      expect(AnalyticsBuckets.sessionDuration(const Duration(minutes: 1)), '30s_2m');
      expect(AnalyticsBuckets.sessionDuration(const Duration(minutes: 9)), '2_10m');
      expect(AnalyticsBuckets.sessionDuration(const Duration(minutes: 59)), '10_60m');
      expect(AnalyticsBuckets.sessionDuration(const Duration(hours: 2)), '60m_plus');
    });

    test('counts stay exact up to three, then bucket', () {
      expect(AnalyticsBuckets.count(0), '0');
      expect(AnalyticsBuckets.count(3), '3');
      expect(AnalyticsBuckets.count(5), '4_5');
      expect(AnalyticsBuckets.count(10), '6_10');
      expect(AnalyticsBuckets.count(50), '10_plus');
    });
  });
}
