import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/wifi_hotspot_segment.dart';
import 'package:tark/feature/transfer/presentation/manager/wifi_hotspot_cubit.dart';
import 'package:tark/feature/transfer/presentation/page/wifi_hotspot_page.dart';

void main() {
  HotspotBridgeState state({
    JoinPhase phase = JoinPhase.idle,
    bool peerConnected = false,
  }) => HotspotBridgeState.initial(WifiHotspotSegment.hotspot).copyWith(
    role: HotspotRole.join,
    joinPhase: phase,
    peerConnected: peerConnected,
  );

  test('Room one-scan enters as soon as exact Wi-Fi bind succeeds', () {
    expect(
      shouldEnterChannelAfterBridgeUpdate(
        roomHandoff: true,
        state: state(phase: JoinPhase.joined),
      ),
      isTrue,
      reason:
          'JoinPhase.joined is emitted only after the selected network is '
          'bound; waiting for a peer packet here deadlocks Room live startup.',
    );
  });

  test('legacy bridge still waits for actual peer traffic', () {
    expect(
      shouldEnterChannelAfterBridgeUpdate(
        roomHandoff: false,
        state: state(phase: JoinPhase.joined),
      ),
      isFalse,
    );
    expect(
      shouldEnterChannelAfterBridgeUpdate(
        roomHandoff: false,
        state: state(phase: JoinPhase.joined, peerConnected: true),
      ),
      isTrue,
    );
  });

  test('Room handoff does not enter on joining or failure states', () {
    for (final phase in <JoinPhase>[
      JoinPhase.idle,
      JoinPhase.joining,
      JoinPhase.invalid,
      JoinPhase.manual,
      JoinPhase.wifiOff,
      JoinPhase.locationOff,
      JoinPhase.lost,
    ]) {
      expect(
        shouldEnterChannelAfterBridgeUpdate(
          roomHandoff: true,
          state: state(phase: phase),
        ),
        isFalse,
        reason: '$phase must stay in recovery/setup until a real bind exists.',
      );
    }
  });
}
