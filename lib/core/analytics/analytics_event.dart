/// The app's complete analytics vocabulary: seven events, their tokens, and
/// the closed set of attribute values each one accepts.
///
/// Two rules shape this file, both learned from what the AdTrace panel can
/// and can't do:
///
/// 1. **Funnel stages are separate events, dimensions are attributes.** The
///    panel builds funnels from event tokens; whether it can also filter a
///    funnel by attribute is not something we want to depend on. So
///    "started → connected → transmitted" are three tokens, while "which
///    transport" is an attribute of each.
/// 2. **Every value is bucketed and comes from an enum.** Raw milliseconds
///    or free text would blow up attribute cardinality and make the
///    breakdowns unreadable, and AdTrace caps attributes at 512 bytes each.
///
/// The enums here are intentionally *not* the app's internal enums (e.g.
/// TransferMode). Analytics vocabulary is a published contract with the
/// dashboards: renaming an internal enum should never silently re-label a
/// year of collected data, so call sites map across explicitly.
library;

/// Which transport carried the session.
enum AnalyticsTransport {
  wifi('wifi'),
  bluetooth('bt'),
  hotspot('hotspot'),
  guest('guest');

  const AnalyticsTransport(this.wire);
  final String wire;
}

/// Which side of the pairing the device played.
enum PairRole {
  host('host'),
  joiner('joiner');

  const PairRole(this.wire);
  final String wire;
}

/// How far a failed pairing attempt got before it died. Ordered roughly by
/// how early it happens, because "where does pairing die" is the single
/// question this whole taxonomy exists to answer.
enum PairStage {
  permission('permission'),
  discover('discover'),
  dial('dial'),
  handshake('handshake'),
  apSetup('ap_setup');

  const PairStage(this.wire);
  final String wire;
}

/// Why a pairing attempt failed. Closed vocabulary on purpose — a free-text
/// reason would produce a long tail nobody can rank, and ranking these by
/// count is exactly how the connectivity backlog gets prioritised.
enum PairFailure {
  permissionDenied('perm_denied'),
  discoverTimeout('discover_timeout'),
  dialRefused('dial_refused'),
  handshakeTimeout('handshake_timeout'),
  apNeverUp('ap_never_up'),
  frameworkRefused('framework_refused'),
  userCancelled('user_cancelled'),
  unknown('unknown');

  const PairFailure(this.wire);
  final String wire;
}

/// What keyed the channel for a transmission.
///
/// No `ptt` value on purpose: the mic control is a self-mute toggle, not a
/// hold-to-talk button (see MicControl) — transmission is VOX-gated, and the
/// default threshold leaves the gate wide open. A `ptt` bucket would collect
/// zero rows forever and quietly imply the app has a feature it doesn't.
enum TxMode {
  vox('vox'),
  music('music');

  const TxMode(this.wire);
  final String wire;
}

/// How a session finished. `connectionLost` vs `userLeft` is the difference
/// between a reliability problem and a satisfied user.
enum SessionEndReason {
  userLeft('user_left'),
  connectionLost('connection_lost'),
  error('error');

  const SessionEndReason(this.wire);
  final String wire;
}

/// Features whose adoption is worth knowing. One event token with this as an
/// attribute (rather than a token each) — these are breakdowns, not funnels.
enum AppFeature {
  selfMute('self_mute'),
  systemAudio('system_audio'),
  musicGain('music_gain'),
  qrScan('qr_scan'),
  homeWidget('home_widget'),
  autoReconnect('auto_reconnect'),
  noiseSuppression('noise_suppression'),
  voiceDefaults('voice_defaults'),
  replayIntro('replay_intro');

  const AppFeature(this.wire);
  final String wire;
}

/// Event tokens as created in the AdTrace panel.
///
/// AdTrace has no track-by-name API — [AdTraceEvent] takes a token and
/// nothing else — so every event here must already exist in the panel. Add a
/// new event there first, then add its token below.
abstract final class AnalyticsTokens {
  static const onboardingFinished = '2sm97f';
  static const pairStarted = 'rx3v5b';
  static const pairConnected = 'x5ptky';
  static const pairFailed = 'jrya90';
  static const firstTransmit = '01k6xn';
  static const sessionEnded = 'ji0po1';
  static const featureUsed = 'dlk4kn';
}

/// Attribute keys. Short because AdTrace counts key length against the
/// 512-byte per-key/value budget, and these are read in panel column
/// headers where long names get truncated anyway.
abstract final class _Attr {
  static const transport = 'transport';
  static const role = 'role';
  static const stage = 'stage';
  static const reason = 'reason';
  static const mode = 'mode';
  static const secs = 'secs';
  static const dur = 'dur';
  static const peers = 'peers';
  static const tx = 'tx';
  static const feature = 'feature';
  static const locale = 'locale';
  static const skipped = 'skipped';
}

/// Bucketing. Every numeric attribute goes through here — see the file
/// header for why raw values never reach the panel.
abstract final class AnalyticsBuckets {
  /// Time-to-connect. Tight buckets at the short end because the difference
  /// between "instant" and "five seconds" is the difference between a
  /// product that feels magic and one that feels broken.
  static String connectSeconds(Duration d) {
    final s = d.inSeconds;
    if (s < 5) return '0_5';
    if (s < 15) return '5_15';
    if (s < 45) return '15_45';
    return '45_plus';
  }

  /// Session length. The 0–30s bucket is the one that matters: a session
  /// that short means they connected and immediately gave up.
  static String sessionDuration(Duration d) {
    final s = d.inSeconds;
    if (s < 30) return '0_30s';
    if (s < 120) return '30s_2m';
    if (s < 600) return '2_10m';
    if (s < 3600) return '10_60m';
    return '60m_plus';
  }

  /// Small counts (peers in a session, transmissions). Exact up to 3 —
  /// distinguishing a duo from a trio drives roadmap decisions — then
  /// bucketed.
  static String count(int n) {
    if (n <= 3) return '$n';
    if (n <= 5) return '4_5';
    if (n <= 10) return '6_10';
    return '10_plus';
  }
}

/// One analytics event: a panel token plus its already-bucketed attributes.
///
/// Constructed only through the named constructors below, which is what
/// keeps the wire format consistent across every call site in the app.
final class AnalyticsEvent {
  const AnalyticsEvent._(this.token, this.attributes);

  final String token;
  final Map<String, String> attributes;

  /// Top of the activation funnel: the user left the intro and reached the
  /// product. Fires for the skip path too — [skipped] is what separates
  /// them, so the panel can ask whether skippers ever go on to connect.
  factory AnalyticsEvent.onboardingFinished({
    required String locale,
    required bool skipped,
  }) => AnalyticsEvent._(AnalyticsTokens.onboardingFinished, {
    _Attr.locale: locale,
    _Attr.skipped: skipped ? 'yes' : 'no',
  });

  /// The user committed to a transport and pairing began.
  factory AnalyticsEvent.pairStarted({
    required AnalyticsTransport transport,
    required PairRole role,
  }) => AnalyticsEvent._(AnalyticsTokens.pairStarted, {
    _Attr.transport: transport.wire,
    _Attr.role: role.wire,
  });

  /// The aha moment: a peer is confirmed on the other end.
  factory AnalyticsEvent.pairConnected({
    required AnalyticsTransport transport,
    required PairRole role,
    required Duration elapsed,
  }) => AnalyticsEvent._(AnalyticsTokens.pairConnected, {
    _Attr.transport: transport.wire,
    _Attr.role: role.wire,
    _Attr.secs: AnalyticsBuckets.connectSeconds(elapsed),
  });

  /// Pairing died. Ranked by count, these are the connectivity backlog.
  factory AnalyticsEvent.pairFailed({
    required AnalyticsTransport transport,
    required PairRole role,
    required PairStage stage,
    required PairFailure reason,
  }) => AnalyticsEvent._(AnalyticsTokens.pairFailed, {
    _Attr.transport: transport.wire,
    _Attr.role: role.wire,
    _Attr.stage: stage.wire,
    _Attr.reason: reason.wire,
  });

  /// First transmission of a session. Connected-but-never-transmitted means
  /// the channel screen isn't teaching people how to talk.
  factory AnalyticsEvent.firstTransmit({
    required AnalyticsTransport transport,
    required TxMode mode,
  }) => AnalyticsEvent._(AnalyticsTokens.firstTransmit, {
    _Attr.transport: transport.wire,
    _Attr.mode: mode.wire,
  });

  /// Session teardown, carrying the whole session's shape in one event —
  /// cheaper and far less noisy than streaming per-minute heartbeats.
  factory AnalyticsEvent.sessionEnded({
    required AnalyticsTransport transport,
    required Duration duration,
    required int peersMax,
    required int txCount,
    required SessionEndReason reason,
  }) => AnalyticsEvent._(AnalyticsTokens.sessionEnded, {
    _Attr.transport: transport.wire,
    _Attr.dur: AnalyticsBuckets.sessionDuration(duration),
    _Attr.peers: AnalyticsBuckets.count(peersMax),
    _Attr.tx: AnalyticsBuckets.count(txCount),
    _Attr.reason: reason.wire,
  });

  /// A feature was used at least once this session. Fired once per session
  /// per feature, not per tap.
  factory AnalyticsEvent.featureUsed(AppFeature feature) =>
      AnalyticsEvent._(AnalyticsTokens.featureUsed, {
        _Attr.feature: feature.wire,
      });

  @override
  String toString() => 'AnalyticsEvent($token, $attributes)';
}
