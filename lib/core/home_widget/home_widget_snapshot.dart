import 'package:equatable/equatable.dart';

/// The one visual state the home-screen widget renders, in the order a
/// session moves through them. Native code switches on this `name` alone —
/// it never re-derives state from the other fields — so adding a case here
/// means adding it to `WidgetState.kt` and `SharedState.swift` too.
enum HomeWidgetSession {
  /// Setup was never finished, so there's no channel to jump into. The
  /// widget shows a "set me up" prompt instead of the go-live button.
  setup,

  /// Nothing running: app closed or sitting outside a channel. The resting
  /// state, and the only one whose action button launches the app.
  idle,

  /// Launched from the widget or otherwise mid-handshake.
  connecting,

  /// Live and quiet — mic open, nobody talking.
  listening,

  /// Live, and someone else is talking (see [HomeWidgetSnapshot.talker]).
  receiving,

  /// Live and this device is transmitting.
  onAir,

  /// Live but self-muted, so VOX can't open the mic.
  muted,

  /// Live session whose link dropped and is retrying automatically.
  reconnecting,

  /// Link is down and not retrying — needs the user to intervene.
  down;

  /// Everything from [connecting] on is a session the app is actually
  /// holding open, which is what gates the widget's background mute/end
  /// controls (there's nothing to control otherwise).
  bool get isLive => this != HomeWidgetSession.setup && this != HomeWidgetSession.idle;
}

/// Raw session facts handed to [HomeWidgetService] for publishing.
///
/// Deliberately unlocalized and theme-free: the service renders the display
/// strings at publish time (see `HomeWidgetServiceImpl._render`) so there's
/// one place that knows about ARB lookups and the active palette.
class HomeWidgetSnapshot extends Equatable {
  const HomeWidgetSnapshot({
    required this.session,
    required this.modeKey,
    required this.callsign,
    required this.peerCount,
    required this.talker,
  });

  /// What the widget shows before the user has ever completed setup.
  const HomeWidgetSnapshot.setup()
    : session = HomeWidgetSession.setup,
      modeKey = '',
      callsign = '',
      peerCount = 0,
      talker = '';

  /// No live session — the resting state published on app exit and whenever
  /// the channel page is torn down.
  const HomeWidgetSnapshot.idle({
    required this.modeKey,
    required this.callsign,
  }) : session = HomeWidgetSession.idle,
       peerCount = 0,
       talker = '';

  final HomeWidgetSession session;

  /// `TransferMode.key` — the same canonical string the mode is persisted
  /// under. Passed as a string rather than the enum so `core/` doesn't have
  /// to depend on the transfer feature: the shared kernel is the one thing
  /// every feature can import, so it can't import them back.
  final String modeKey;

  final String callsign;

  /// Other people on the channel, excluding this device.
  final int peerCount;

  /// Who's transmitting to us right now; empty unless
  /// [session] is [HomeWidgetSession.receiving].
  final String talker;

  @override
  List<Object?> get props => [session, modeKey, callsign, peerCount, talker];
}
