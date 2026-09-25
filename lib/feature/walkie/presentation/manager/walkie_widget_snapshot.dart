import '../../../../core/home_widget/home_widget_snapshot.dart';
import '../../../transfer/api/transfer_api.dart';
import 'walkie_talkie_cubit.dart';

/// What the home-screen widget shows for [s].
///
/// The widget is the only view of a session once the app is in the
/// background, so [WalkieTalkieCubit] mirrors every state change through this.
/// Pure: the same state always yields the same snapshot, which is what lets
/// [HomeWidgetService.publish] drop repeats.
HomeWidgetSnapshot walkieWidgetSnapshot(WalkieTalkieState s) {
  // Same precedence the on-screen scope pill uses (see VisualizerSection),
  // so the widget and the channel page never disagree about what's
  // happening — with link health on top, since a dropped link makes every
  // other state a lie.
  final session = switch (s) {
    // Before isReady, so a channel that failed to open reads as down on the
    // home screen rather than connecting forever.
    _ when s.startFailed => HomeWidgetSession.down,
    _ when !s.isReady => HomeWidgetSession.connecting,
    _ when s.connectionHealth.status == ConnectionHealthStatus.down =>
      HomeWidgetSession.down,
    // Every rung that is not live reads as reconnecting here, rather than
    // naming them: the widget has one glyph for "the app is working on it",
    // and matching only ConnectionHealthStatus.reconnecting would let the
    // harder rung above it (renegotiating) fall through to "listening" — the
    // widget cheerfully reporting a healthy channel during the worst state
    // the link can be in short of down.
    //
    // Degraded is live and so lands below with the ordinary states, which is
    // the intent: the quiet rung is quiet here too.
    _ when !s.connectionHealth.isLive => HomeWidgetSession.reconnecting,
    _ when s.isTransmitting => HomeWidgetSession.onAir,
    // Muted only wins when nothing is actually going out — a music share
    // keeps the channel hot even with the mic closed.
    _ when s.isSelfMuted => HomeWidgetSession.muted,
    _ when s.isSomeoneElseTalking => HomeWidgetSession.receiving,
    _ => HomeWidgetSession.listening,
  };
  return HomeWidgetSnapshot(
    session: session,
    modeKey: s.transferMode.key,
    callsign: s.myName,
    peerCount: s.activeUsers.length,
    talker: session == HomeWidgetSession.receiving ? _talkerName(s) : '',
  );
}

String _talkerName(WalkieTalkieState s) {
  for (final u in s.activeUsers) {
    if (u.isTalking) return u.name;
  }
  return '';
}
