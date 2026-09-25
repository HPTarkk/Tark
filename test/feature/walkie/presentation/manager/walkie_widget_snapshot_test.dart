import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/home_widget/home_widget_snapshot.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/walkie/domain/entity/channel_user.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_widget_snapshot.dart';

void main() {
  final ready = WalkieTalkieState.initial().copyWith(
    isReady: true,
    myName: 'Pedram',
  );
  ChannelUser peer(String name, {bool talking = false}) => ChannelUser(
    id: name,
    name: name,
    isTalking: talking,
    lastSeen: DateTime.utc(2026, 9, 25),
  );

  HomeWidgetSession sessionOf(WalkieTalkieState s) =>
      walkieWidgetSnapshot(s).session;

  test('a channel that failed to open reads as down, even before ready', () {
    expect(
      sessionOf(WalkieTalkieState.initial().copyWith(startFailed: true)),
      HomeWidgetSession.down,
    );
    expect(
      sessionOf(WalkieTalkieState.initial()),
      HomeWidgetSession.connecting,
    );
  });

  test('link health outranks everything the channel is doing', () {
    final talking = ready.copyWith(isTransmitting: true);
    expect(
      sessionOf(
        talking.copyWith(connectionHealth: const ConnectionHealth.down()),
      ),
      HomeWidgetSession.down,
    );
    expect(
      sessionOf(
        talking.copyWith(
          connectionHealth: const ConnectionHealth.renegotiating(),
        ),
      ),
      HomeWidgetSession.reconnecting,
    );
    // Degraded is live: the quiet rung stays quiet on the home screen too.
    expect(
      sessionOf(
        talking.copyWith(connectionHealth: const ConnectionHealth.degraded()),
      ),
      HomeWidgetSession.onAir,
    );
  });

  test('on air beats muted, muted beats receiving', () {
    final busy = ready.copyWith(
      isSelfMuted: true,
      activeUsers: [peer('Sara', talking: true)],
    );
    expect(
      sessionOf(busy.copyWith(isTransmitting: true)),
      HomeWidgetSession.onAir,
    );
    expect(sessionOf(busy), HomeWidgetSession.muted);
    expect(
      sessionOf(busy.copyWith(isSelfMuted: false)),
      HomeWidgetSession.receiving,
    );
  });

  test('names the talker only while receiving, and counts peers', () {
    final receiving = walkieWidgetSnapshot(
      ready.copyWith(activeUsers: [peer('Ali'), peer('Sara', talking: true)]),
    );
    expect(receiving.talker, 'Sara');
    expect(receiving.peerCount, 2);
    expect(receiving.callsign, 'Pedram');

    final listening = walkieWidgetSnapshot(
      ready.copyWith(activeUsers: [peer('Ali')]),
    );
    expect(listening.session, HomeWidgetSession.listening);
    expect(listening.talker, '');
  });
}
