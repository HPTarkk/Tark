import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/analytics/analytics.dart';
import '../../../../core/analytics/analytics_event.dart';
import '../../../../core/analytics/pairing_attempt.dart';
import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/home_widget/home_widget_service.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../transfer/domain/service/hotspot_link_keeper.dart';
import '../../../../core/home_widget/home_widget_snapshot.dart';
import '../../../../core/home_widget/widget_control_channel.dart';
import '../../../../core/settings/noise_suppression_engine.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/settings/vox_margin.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/lan_ipv4.dart';
import '../../../../core/utils/dispose_bag.dart';
import '../../../../core/utils/fallback_display_name.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio/api/audio_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/channel_user.dart';
import '../../domain/service/channel_roster.dart';

/// Placeholder local id used in Bluetooth mode, where there's no IP concept
/// and the peer connection (established before this cubit is even built) is
/// what actually gates transmission — not this id's value. Kept non-empty
/// and distinct from '0.0.0.0' so the WiFi-oriented online check below
/// doesn't misfire.
const _kBluetoothLocalId = 'bluetooth-peer';

@injectable
class WalkieTalkieCubit extends Cubit<WalkieTalkieState>
    with WidgetsBindingObserver {
  final AudioEngine _audioEngine;
  final TransferRepository _transferRepository;
  final TransferModeStore _modeStore;
  final SettingsRepository _settingsRepository;
  final SfxPlayer _sfx;
  final SessionWakeLock _keepAlive;
  final HomeWidgetService _homeWidget;
  final WidgetControlChannel _widgetControl;
  final DeviceIdentity _identity;
  final HotspotLinkKeeper _linkKeeper;
  final Analytics _analytics;
  final LicenseGate _gate;

  /// Only ever used for [openWifiSettings] — the channel screen never joins a
  /// network, but when it finds itself without an address the fastest fix is
  /// the system Wi-Fi panel, and this already knows how to raise it.
  final HotspotJoiner _wifiSettings;

  StreamSubscription<AudioFrame>? _frameSub;
  StreamSubscription<AudioEngineStatus>? _statusSub;
  StreamSubscription<WakiPacket>? _packetSub;
  StreamSubscription<ConnectionHealth>? _linkSub;
  StreamSubscription<HotspotLinkState>? _hotspotLinkSub;
  StreamSubscription<WidgetControlAction>? _widgetControlSub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;

  /// Registry for the eight subscriptions/timers above, keyed by name.
  /// [DisposeBag.register] cancels whatever was previously registered under
  /// the same key first, so re-wiring on a retry can't leave a duplicate
  /// running even if a future edit forgets to cancel one by hand. Not used by
  /// [close] — that teardown deliberately fires cancels before other
  /// side effects, ahead of any await, which a bag that awaits each cancel
  /// in turn would reorder.
  final DisposeBag _resources = DisposeBag();

  WalkieTalkieCubit(
    this._audioEngine,
    this._transferRepository,
    this._modeStore,
    this._settingsRepository,
    this._sfx,
    this._keepAlive,
    this._homeWidget,
    this._widgetControl,
    this._identity,
    this._linkKeeper,
    this._wifiSettings,
    this._analytics,
    this._gate,
  ) : super(WalkieTalkieState.initial()) {
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  /// When the app last left the foreground, so a resume can say how long the
  /// session ran unattended — the window nearly every mid-session failure
  /// happens in.
  DateTime? _backgroundedAt;

  /// Screen off and screen on are the two moments this session is most likely
  /// to break, and the two the user can point at ("I locked it and it went
  /// quiet"). Both ends of that get handled here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (isClosed) return;
    switch (lifecycle) {
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        _backgroundedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final away = _backgroundedAt;
        _backgroundedAt = null;
        Logger.diagnostic(
          'channel: resumed'
          '${away == null ? '' : ' after ${DateTime.now().difference(away).inSeconds}s away'}'
          ' — peers=${state.activeUsers.length} local=${state.localId} '
          'health=${state.connectionHealth.status.name} '
          'mic=${state.micDelivering} heard=${!state.unheardByPeers}',
        );
        // Whatever peers did or didn't say while the phone was locked is not
        // evidence about the link now: the OS can suspend this process
        // outright, and every second of that would otherwise be counted as
        // "nobody could hear me". Moved forward rather than cleared — clearing
        // it would let the check fall back to the last confirmation, which is
        // the very timestamp on the far side of the gap we are discounting.
        _unheardSince = DateTime.now();
        // Capture chunks buffered up on the platform channel while the isolate
        // was stalled, and they land as one burst. That backlog is stale by
        // definition — it is audio from while the phone was locked — so it goes
        // rather than being played out late. [MusicMixer.floodSamples] is the
        // backstop for the same thing when the burst arrives after this runs.
        //
        // Deliberately does NOT touch `_musicSub`: the [SystemAudioCapture]
        // subscription must survive backgrounding on its own, same as the
        // mic. Only the stale queue contents get discarded here — see the
        // motorcycle field-test runbook's reliability-gate notes before
        // adding a cancel/restart of `_musicSub` anywhere in this handler.
        if (state.isSharingSystemAudio) _musicMixer.clear();
        // The address can have changed under us (a joiner the OS moved between
        // networks), and the next presence tick is up to 2s away — which is a
        // long time to spend transmitting from an address nobody can reach.
        _refreshId();
        _broadcastPresence();
      case AppLifecycleState.inactive:
        // A notification shade or a call banner. Nothing about the session
        // changes, so nothing here should either.
        break;
    }
  }

  /// When the channel finished opening, for the "nobody else is here" check —
  /// which is only worth saying once enough time has passed for someone to
  /// have shown up.
  DateTime? _readyAt;

  /// Last mic frame that actually arrived. The engine can report itself
  /// started and then deliver nothing at all (see [_checkMicHealth]), so
  /// "started" is not evidence the mic works — a frame is.
  DateTime? _lastFrameAt;

  /// When this device first had no usable local address, so a momentary gap
  /// during a network change isn't announced as a failure.
  DateTime? _noAddressSince;

  /// Last time a peer's presence packet listed *us* among the devices it can
  /// hear — proof our transmissions are arriving somewhere.
  ///
  /// Everything else this cubit grades is about receiving. A phone whose
  /// outgoing path has died still has a bound socket, a healthy link, a
  /// populated roster and a working mic, and every check on the
  /// troubleshooting sheet goes green while nobody can hear it. This is the
  /// only local evidence to the contrary there is.
  DateTime? _lastHeardByPeerAt;

  /// When peers started reporting they can't hear us, so a single dropped
  /// presence packet isn't treated as going mute.
  DateTime? _unheardSince;

  /// How long peers must consistently report not hearing us before it counts.
  /// Several presence ticks (they arrive every 2s), so this needs a sustained
  /// disagreement rather than one lost datagram.
  static const _unheardAfter = Duration(seconds: 7);

  /// Silence longer than this, with the engine claiming to be started, means
  /// the mic is not actually feeding us. Generous: a slow device can take a
  /// couple of seconds to deliver its first callback.
  static const _micSilentAfter = Duration(seconds: 6);

  /// How long a missing local address must persist before it's reported.
  static const _noAddressGrace = Duration(seconds: 5);

  /// How long to sit in an empty channel before saying so. Long enough that
  /// a peer joining normally is never preceded by a "you're alone" card.
  static const _aloneAfter = Duration(seconds: 20);

  /// Wraps [_init] so a throw anywhere in it becomes a visible, recoverable
  /// state instead of a channel screen stuck on "connecting" forever.
  ///
  /// This used to be a bare `_init()` call in the constructor. Anything that
  /// threw in there — a settings read, the transport's first listen — left
  /// `isReady` false with no packet subscription, no presence timer and no
  /// health stream, and absolutely nothing on screen to say so. The only way
  /// out was to leave the channel, and nothing told the user even that much.
  Future<void> _start() async {
    try {
      await _init();
    } catch (e, st) {
      Logger.log('Channel failed to open: $e\n$st');
      if (!isClosed) {
        emit(state.copyWith(startFailed: true));
        _sfx.play(SfxEvent.error);
      }
    }
  }

  /// "Try again" from the failure banner. Drops whatever the failed attempt
  /// managed to wire up first, so the retry starts from the same place a
  /// fresh session would rather than stacking a second set of subscriptions.
  Future<void> retryStart() async {
    if (isClosed) return;
    await _resources.disposeAll();
    _frameSub = null;
    _statusSub = null;
    _packetSub = null;
    _linkSub = null;
    _hotspotLinkSub = null;
    _widgetControlSub = null;
    _presenceTimer = null;
    _cleanupTimer = null;
    _readyAt = null;
    _lastFrameAt = null;
    _noAddressSince = null;
    _lastHeardByPeerAt = null;
    _unheardSince = null;
    emit(
      state.copyWith(
        startFailed: false,
        isReady: false,
        micDelivering: true,
        networkMissing: false,
        isAlone: false,
        unheardByPeers: false,
      ),
    );
    await _start();
  }

  /// "Restart mic" — re-opens the capture device without leaving the channel.
  /// The engine's epoch guard makes a second [AudioEngine.start] safe, and it
  /// re-asks for the permission if that's what's missing, so this one action
  /// covers both mic failures the UI can show.
  Future<void> restartMic() async {
    if (isClosed) return;
    _lastFrameAt = DateTime.now();
    emit(state.copyWith(micDelivering: true));
    try {
      await _audioEngine.start();
    } catch (e) {
      Logger.log('Mic restart failed: $e');
    }
  }

  /// "Reconnect" — cuts any backoff wait short and rebinds the transport.
  /// Shared by the health banner and the troubleshooting sheet.
  void reconnectNow() {
    _transferRepository.retryNow();
    _refreshId();
  }

  /// "Repair link" — rebuilds the outgoing path after peers have reported they
  /// can't hear us.
  ///
  /// Offered as a manual action as well as run automatically, because the
  /// automatic one is rate-limited and a user staring at the warning deserves
  /// a button that does something. Clears the flag so the next presence round
  /// gets to answer honestly rather than leaving a stale warning up.
  void repairSendPath() {
    Logger.diagnostic('transmit: manual send-path repair requested');
    _transferRepository.repairSendPath();
    // From now: the repair deserves a full grace period to prove itself, and
    // clearing this outright would re-arm the warning against a confirmation
    // that predates the repair.
    _unheardSince = DateTime.now();
    _refreshId();
    if (!isClosed && state.unheardByPeers) {
      emit(state.copyWith(unheardByPeers: false));
    }
    _broadcastPresence();
  }

  /// Raises the system Wi-Fi panel (and, on older Androids where an app may
  /// still flip the radio, just turns it on). The address check runs on its
  /// own timer, so a user who joins a network from here watches the warning
  /// clear itself on the way back.
  Future<void> openWifiSettings() async {
    try {
      await _wifiSettings.enableWifi();
    } catch (e) {
      Logger.log('Could not open Wi-Fi settings: $e');
    }
    _refreshId();
  }

  /// Outgoing mic frames, exposed for audio-rate widgets (visualizer, VOX
  /// meter) so presentation never touches the audio feature directly.
  Stream<AudioFrame> get frames => _audioEngine.frames;

  /// Incoming channel audio, for the visualizer while someone else is talking.
  Stream<AudioFrame> get receivedFrames => _audioEngine.receivedFrames;

  Future<void> _init() async {
    // One resolved profile rather than three getters: with the riding preset
    // on, the values the engine runs are the preset's, not the stored ones.
    final profile = await _settingsRepository.getAudioProfile();
    final voxMargin = profile.voxMargin;
    final noiseSuppression = profile.noiseSuppression;
    final noiseSuppressionEngine = profile.noiseSuppressionEngine;
    final ridingPreset = profile.fromPreset;
    final musicGain = await _settingsRepository.getMusicGain();

    // The page can be exited while _init is still awaiting (fast back-out).
    // close() has then already run, so bail instead of resurrecting
    // subscriptions and timers nobody will ever cancel.
    if (isClosed) return;

    _audioEngine.setNoiseSuppression(noiseSuppression);
    _audioEngine.setNoiseSuppressionEngine(noiseSuppressionEngine);
    // Attached before start() so no status event can fire and be missed —
    // the controller is a plain broadcast stream, not a replay one.
    _statusSub = _resources.register(
      'status',
      _audioEngine.status.listen((status) {
        if (!isClosed && status.hasPermission != state.hasPermission) {
          if (state.hasPermission && !status.hasPermission) {
            _sfx.play(SfxEvent.error);
          }
          emit(state.copyWith(hasPermission: status.hasPermission));
        }
      }),
    );

    // Mic start and network-identity resolution are independent — run them
    // concurrently. Previously localId was awaited FIRST, so quick access
    // (which can reach this within milliseconds of process cold-start, with
    // none of Landing's incidental warm-up while the Wi-Fi stack settles)
    // could leave the mic/visualizer waiting on a slow or not-yet-ready
    // network lookup for no reason. localId self-heals a few seconds later
    // regardless, via _refreshId() on every presence tick.
    final audioStart = _audioEngine.start();
    final localId = await _getLocalId();
    final storedName = await _settingsRepository.getMyName();
    // Never derived from the address: this name is broadcast with every
    // packet and shows up in everyone else's roster.
    final myName = storedName.isEmpty
        ? localizedFallbackDisplayName(
            await _settingsRepository.getLocaleCode(),
            localId,
          )
        : storedName;

    if (isClosed) return;
    emit(
      state.copyWith(
        localId: localId,
        myName: myName,
        voxMargin: voxMargin,
        noiseSuppression: noiseSuppression,
        noiseSuppressionEngine: noiseSuppressionEngine,
        ridingPreset: ridingPreset,
        musicGain: musicGain,
        transferMode: _modeStore.mode,
        myRole: _transferRepository.sessionRole,
      ),
    );

    await audioStart;
    if (isClosed) return;

    // Keep the CPU + Wi-Fi awake for the whole session so audio and the
    // transport survive the screen going off (the motorcycle case). Android
    // foreground service + wake/Wi-Fi/multicast locks; a no-op elsewhere.
    unawaited(_keepAlive.start());

    _frameSub = _resources.register(
      'frame',
      _audioEngine.frames.listen(
        _onAudioFrame,
        onError: (Object e) => Logger.log('AudioFrame error: $e'),
      ),
    );

    _packetSub = _resources.register(
      'packet',
      _transferRepository.startListening().listen(
        _onPacketReceived,
        onError: (Object e) => Logger.log('Packet error: $e'),
      ),
    );

    _transferRepository.setAutoReconnectEnabled(
      await _settingsRepository.getAutoReconnectEnabled(),
    );
    if (isClosed) return;

    // Every transport's connect() stream reflects the same unified health
    // signal — for Bluetooth/Guest that's the 1-to-1 peer link, for WiFi
    // it's the UDP socket's bind/rebind lifecycle plus a liveness watchdog
    // (see WifiTransferRepositoryImpl). A drop means the same
    // "link lost — reconnecting" banner + sound applies, so this is no
    // longer gated to specific transports.
    _linkSub = _resources.register(
      'link',
      _transferRepository.connect().listen(_applyHealth),
    );

    // The hotspot link underneath the transport, which has its own failure
    // modes the sockets cannot see: a joiner the OS pulled off the AP, or a
    // host whose AP came back under a new random SSID the peer has no way to
    // learn. Nothing subscribed to this during a live session before, so those
    // were invisible — the call simply went quiet and stayed quiet. Only the
    // bad news is mapped here; "up" is left to the transport, which knows the
    // difference between a link being back and traffic actually flowing again.
    _hotspotLinkSub = _resources.register(
      'hotspotLink',
      _linkKeeper.states.listen((link) {
        if (isClosed) return;
        switch (link) {
          case HotspotLinkState.recovering:
            _applyHealth(const ConnectionHealth.reconnecting());
          case HotspotLinkState.lost:
            _applyHealth(const ConnectionHealth.down());
          case HotspotLinkState.up || HotspotLinkState.idle:
            break;
        }
      }, onError: (Object e) => Logger.log('Hotspot link state error: $e')),
    );

    // MUTE on the home-screen widget, pressed while the app is in the
    // background. Scoped to the live cubit on purpose: no session, nothing
    // subscribed, so a stale widget button can't mute a channel that the
    // user has already left.
    _widgetControlSub = _resources.register(
      'widgetControl',
      _widgetControl.actions.listen((action) {
        if (isClosed) return;
        if (action == WidgetControlAction.toggleMute) toggleSelfMute();
      }),
    );

    _presenceTimer = _resources.register(
      'presence',
      Timer.periodic(const Duration(seconds: 2), (_) {
        _broadcastPresence();
        _gradeLink();
        _logTransmitState();
        _logMusicHealth();
        unawaited(_checkMusicBlocked());
        // Keeps the widget's "last published" timestamp advancing while the
        // session is live but unchanging. onChange alone can go quiet for
        // minutes (nobody talking, roster steady), and the native side
        // demotes state it hasn't heard about to "idle". publish() throttles
        // this down to one actual write every 30s.
        unawaited(_homeWidget.publish(_widgetSnapshot(state)));
      }),
    );
    _cleanupTimer = _resources.register(
      'cleanup',
      Timer.periodic(const Duration(seconds: 3), (_) => _cleanupStaleUsers()),
    );

    // Both clocks start here rather than at construction: everything before
    // this point is legitimate warm-up, and grading the mic or the roster
    // against it would report a failure for a channel that is merely opening.
    _readyAt = DateTime.now();
    _lastFrameAt = DateTime.now();

    // Plain Wi-Fi has no connect screen to own its funnel events — peers just
    // appear over UDP broadcast — so the channel itself is the pairing
    // attempt. Without this the funnel would be missing the app's default and
    // most-used transport entirely, which would make every cross-transport
    // comparison in the panel a lie. The other three transports each have a
    // connect screen that already reports for them.
    if (_modeStore.mode == TransferMode.wifi) {
      _wifiPairing.start(
        _transferRepository.sessionRole == SessionRole.host
            ? PairRole.host
            : PairRole.joiner,
      );
    }

    emit(state.copyWith(isReady: true));
    _sfx.play(SfxEvent.channelJoin);
    _broadcastPresence();
  }

  /// Applies a link-health reading, with the cue and the codec reset that go
  /// with a transition. Shared by the transport's own health stream and the
  /// hotspot link keeper, so a drop sounds and looks the same whichever of the
  /// two noticed it first.
  void _applyHealth(ConnectionHealth health) {
    if (isClosed || state.connectionHealth == health) return;
    // Graded on [ConnectionHealth.isLive], not isHealthy. A degraded link is
    // being repaired quietly and by design says nothing — playing link-lost
    // for it would put the alarm back on exactly the two-second dips the
    // degraded rung exists to absorb.
    final wasLive = state.connectionHealth.isLive;
    emit(state.copyWith(connectionHealth: health));
    if (wasLive && !health.isLive) {
      _sfx.play(SfxEvent.linkLost);
    } else if (!wasLive && health.isLive) {
      _sfx.play(SfxEvent.linkRestored);
      // Recovering from a drop can leave stale jitter-buffer/decoder state
      // from before the gap — clear it so playback doesn't pick up
      // mid-buffer or garble the first packets from a resumed sender.
      _audioEngine.resetPlayback();
      _transferRepository.resetCodecState();
    }
  }

  /// Mirrors every state change onto the home-screen widget.
  ///
  /// Hooked here rather than at each emit site so no future emit can forget
  /// it — the widget is the only view of this session once the app is in the
  /// background, and a missed transition strands it showing the wrong thing.
  /// [HomeWidgetService.publish] drops consecutive identical payloads, which
  /// is what keeps this cheap despite firing on audio-rate flag flips.
  @override
  void onChange(Change<WalkieTalkieState> change) {
    super.onChange(change);
    unawaited(_homeWidget.publish(_widgetSnapshot(change.nextState)));
    // Cheapest possible peak-tracking, hooked here for the same reason the
    // widget publish is: no emit site can forget it. This runs on audio-rate
    // flag flips, so it must stay two comparisons and nothing else.
    final peers = change.nextState.activeUsers.length;
    if (peers > _peersMax) _peersMax = peers;
  }

  /// The pairing attempt for plain Wi-Fi sessions only — see where it's
  /// started in [_init]. Left permanently closed for every other transport,
  /// which makes all of its methods no-ops there.
  late final PairingAttempt _wifiPairing = PairingAttempt(
    _analytics,
    transport: AnalyticsTransport.wifi,
  );

  /// Records first use of a feature this session, at most once.
  void _useFeature(AppFeature feature) {
    if (_featuresUsed.add(feature)) {
      _analytics.track(AnalyticsEvent.featureUsed(feature));
    }
  }

  HomeWidgetSnapshot _widgetSnapshot(WalkieTalkieState s) {
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

  // ── Session analytics bookkeeping ──────────────────────────────────────
  // All of it collapses into a single session_ended event at close(), rather
  // than a stream of per-minute heartbeats: one row per session is both far
  // cheaper and the shape the funnel actually reads.

  /// Peak concurrent peers. Whether sessions are mostly duos or mostly
  /// groups decides which features are worth building, so it's the one
  /// number worth carrying through the whole session.
  int _peersMax = 0;

  /// Voice bursts — how many times the VOX gate opened. A music cast keys
  /// the channel continuously and deliberately doesn't count here; this is
  /// meant to answer "did they actually talk", not "was the channel hot".
  int _txCount = 0;

  bool _firstTransmitSent = false;

  /// Features already reported this session — [_useFeature] fires once per
  /// feature per session, so a user who taps mute forty times counts once.
  final Set<AppFeature> _featuresUsed = {};

  // Hangover + pre-roll VOX shaping — see [VoxGate] for the why.
  final VoxGate _voxGate = VoxGate();

  // Ambient level, so the VOX threshold rides the background instead of being
  // tuned once and then wrong for the rest of the ride — see
  // [NoiseFloorTracker].
  final NoiseFloorTracker _noiseFloor = NoiseFloorTracker();
  bool _prevVoiceOpen = false;

  /// Starts true so the first frame with no address reports the gate closing.
  bool _prevIsOnline = true;

  // Roster bookkeeping (join/leave/talk-timeout) — see [ChannelRoster].
  final ChannelRoster _roster = const ChannelRoster();

  // System-audio (music) sharing: capture chunks queue up in the mixer,
  // which re-cuts them onto the mic's 20 ms frame grid — see [MusicMixer].
  //
  // The mixer is deliberately NOT cleared when a cast ends by itself: the
  // reason it ended is what a report needs, and its counters are the record of
  // it — see [_stopSharingSystemAudio].
  StreamSubscription<List<double>>? _musicSub;
  final MusicMixer _musicMixer = MusicMixer();

  // Level of the captured system audio (~10 Hz, one value per capture
  // chunk), for the music-cast equalizer. Same pattern as [frames]: an
  // audio-rate side stream so the UI can animate without state emissions.
  final _musicLevelController = StreamController<double>.broadcast();
  Stream<double> get musicLevels => _musicLevelController.stream;

  // One-shot notices about system-audio sharing (currently just the
  // capture-stalled case below) for the page to show as a toast. Side channel
  // rather than state: it's a transient event, not something to redraw for.
  final _systemAudioMessageController = StreamController<String>.broadcast();
  Stream<String> get systemAudioMessages =>
      _systemAudioMessageController.stream;

  void _onAudioFrame(AudioFrame frame) {
    // Proof the capture device is genuinely alive — see [_checkMicHealth].
    _lastFrameAt = DateTime.now();

    // Full duplex: TX and RX run independently, same as a phone call. No
    // half-duplex gate — the platform's voice processing (echo cancellation /
    // noise suppression / AGC) is engaged for the session: on Android via the
    // VOICE_COMMUNICATION preset plus explicitly-attached AEC/NS/AGC effects
    // (see AudioSessionHandler.attachEffects), on iOS via AVAudioSession
    // voiceChat. Residual echo can still leak on loudspeaker with weak device
    // AEC; headphones avoid it entirely.

    // No network → never mark as transmitting.
    final isOnline = state.localId.isNotEmpty && state.localId != '0.0.0.0';
    // This gate silences transmission completely while the phone still shows a
    // live channel and still plays everything it receives — one-way audio with
    // nothing on screen to explain it. Worth a line whenever it flips.
    if (isOnline != _prevIsOnline) {
      _prevIsOnline = isOnline;
      Logger.diagnostic(
        isOnline
            ? 'transmit: enabled, local address ${state.localId}'
            : 'transmit: DISABLED — no local address (localId '
                  '"${state.localId}"), nothing will be sent',
      );
    }

    // Self-mute overrides VOX: the gate still advances (its envelope stays
    // correct for the instant the user unmutes) but an open gate no longer
    // keys the channel. Music casting keeps the channel keyed regardless —
    // muting silences your voice, not a music share you started.
    // The floor sees every frame, including the ones that key the channel: it
    // decides for itself which are background and which are speech, and hiding
    // the loud ones from it would leave it estimating from half the signal.
    _noiseFloor.observe(frame.rms);
    // Resolved once and reused: the gate and the transmit expander have to be
    // told the same absolute level. The stored value is a *margin* now — a
    // distance above the background — so handing that number to anything
    // expecting a level would be nonsense arithmetic rather than a bad setting.
    final voxLevel = _noiseFloor.thresholdFor(state.voxMargin);
    final gateOpen = _voxGate.advance(frame.rms, voxLevel);
    final voiceOpen = gateOpen && !state.isSelfMuted;
    if (isOnline && voiceOpen != _prevVoiceOpen) {
      _sfx.play(voiceOpen ? SfxEvent.pttOpen : SfxEvent.pttClose);
      // Light tactile confirmation that the channel just keyed up — only on
      // open, not close, so a run of short words doesn't buzz repeatedly.
      if (voiceOpen) unawaited(HapticFeedback.lightImpact());
      if (voiceOpen) _txCount++;
    }
    _prevVoiceOpen = voiceOpen;
    final sharingMusic = state.isSharingSystemAudio;
    // Music sharing keeps the channel keyed continuously; voice rides on
    // top of it. Without sharing, VOX (with hangover) gates as usual.
    final isTransmitting =
        _audioEngine.currentStatus.hasPermission &&
        isOnline &&
        (voiceOpen || sharingMusic);

    _txFramesSeen++;
    if (isTransmitting) {
      final buffered = _voxGate.drainPreroll();
      if (voiceOpen && !state.isTransmitting) {
        // Gate just opened — flush the pre-roll so the word onset survives.
        _txPrerollFlushes++;
        for (final samples in buffered) {
          _txPrerollFrames++;
          _transferRepository.sendAudio(
            _audioEngine.processForTransmit(samples, voxLevel),
            state.myName,
          );
        }
      }
      var outgoing = voiceOpen
          ? _audioEngine.processForTransmit(frame.samples, voxLevel)
          : List<double>.filled(frame.samples.length, 0.0);
      if (sharingMusic) {
        outgoing = _musicMixer.mix(outgoing, state.musicGain);
      }
      _txFramesSent++;
      _transferRepository.sendAudio(outgoing, state.myName);
    } else {
      _txFramesGated++;
      _voxGate.bufferWhileClosed(frame.samples);
    }

    if (isTransmitting != state.isTransmitting) {
      // The activation funnel's last step. Connected-but-never-transmitted is
      // the failure this exists to detect: it means the channel screen isn't
      // teaching people how to talk, which no crash report would ever show.
      if (isTransmitting && !_firstTransmitSent) {
        _firstTransmitSent = true;
        _analytics.track(
          AnalyticsEvent.firstTransmit(
            transport: state.transferMode.analytics,
            mode: voiceOpen ? TxMode.vox : TxMode.music,
          ),
        );
      }
      emit(state.copyWith(isTransmitting: isTransmitting));
    }
  }

  // Last reported mixer counters, so the log below stays quiet unless
  // something actually changed.
  int _lastMusicDropouts = 0;
  int _lastMusicTrims = 0;
  int _lastMusicFloods = 0;

  /// Level below which a capture chunk counts as silence. The same threshold
  /// the equalizer uses to decide it is flatlining, so what the log says and
  /// what the card shows can never disagree.
  static const double _kMusicAudibleLevel = 0.004;

  /// Since when every captured chunk has been silent, or null if the last one
  /// carried audio.
  DateTime? _musicSilentSince;

  /// Whether this cast has *ever* produced audible capture. A device that has
  /// managed it once is not the blocked case, whatever it does later.
  bool _musicEverAudible = false;

  /// Whether the blocked-capture diagnosis has already been delivered, so it is
  /// said once per cast rather than every tick.
  bool _musicBlockedReported = false;

  /// How long capture must be silent before another app claiming to be playing
  /// counts as this device refusing to hand over the audio.
  ///
  /// Generous on purpose: starting the cast before choosing a song is normal
  /// (the idle copy invites exactly that), and a cast must never be second-
  /// guessed for a pause between tracks.
  static const _musicBlockedAfter = Duration(seconds: 8);

  /// Reports the music cast's buffer health while one is running.
  ///
  /// The mixer sits between two clocks that nothing synchronises, and a
  /// stutter there is indistinguishable from a network stutter by ear — which
  /// is exactly why this was worth chasing through the transport first.
  /// Dropouts climbing means the cushion is losing to capture jitter; trims
  /// climbing means the two clocks are drifting apart; both at once means the
  /// cushion is simply too small for this device.
  // ── Transmit diagnostics ──────────────────────────────────────────────────
  //
  // The capture line in AudioEngineImpl says the mic produced frames; this
  // says what this cubit then did with them. Between the two sits VOX,
  // self-mute and the online gate, and any of the three can silently swallow
  // a whole session's speech — which reads on the other phone as "I could not
  // hear you at all" and reads here, without these counters, as nothing.
  int _txFramesSeen = 0;
  int _txFramesSent = 0;
  int _txFramesGated = 0;
  int _txPrerollFlushes = 0;
  int _txPrerollFrames = 0;
  DateTime _lastTxLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _txLogInterval = Duration(seconds: 15);

  /// One line describing the VOX/transmit decision over the last window.
  ///
  /// Deliberately reports the *ratio*: frames arriving versus frames actually
  /// put on the wire is what separates "the mic was dead" from "VOX never
  /// opened" from "we were muted the whole time", and those three have
  /// identical symptoms and completely different fixes.
  void _logTransmitState() {
    final now = DateTime.now();
    if (now.difference(_lastTxLogAt) < _txLogInterval) return;
    final window = now.difference(_lastTxLogAt);
    _lastTxLogAt = now;
    if (window.inSeconds > 60 || _txFramesSeen == 0) {
      _resetTxCounters();
      return;
    }
    Logger.diagnostic(
      'transmit: ${window.inSeconds}s window — frames=$_txFramesSeen '
      'sent=$_txFramesSent gated=$_txFramesGated '
      'preroll=$_txPrerollFrames/${_txPrerollFlushes}bursts '
      // Margin, measured background and the level they resolve to. All three,
      // because a field report of "it kept cutting me off" is unattributable
      // with only one: the setting alone cannot say what the mic was hearing,
      // and the level alone cannot say whether the rider or the room chose it.
      'vox=${state.voxMargin.toStringAsFixed(2)}'
      '/${VoxMargin.decibelsFor(state.voxMargin).toStringAsFixed(1)}dB '
      'floor=${_noiseFloor.noiseFloor?.toStringAsFixed(4) ?? '-'} '
      'gate=${_noiseFloor.thresholdFor(state.voxMargin).toStringAsFixed(4)} '
      // Which profile produced that vox figure. A field-test log where the
      // gate behaved unexpectedly is unreadable without knowing whether the
      // rider was on the preset or their own sliders.
      '${state.ridingPreset ? 'riding ' : ''}'
      'muted=${state.isSelfMuted} music=${state.isSharingSystemAudio} '
      'peers=${state.activeUsers.length} localId=${state.localId}',
    );
    _resetTxCounters();
  }

  void _resetTxCounters() {
    _txFramesSeen = 0;
    _txFramesSent = 0;
    _txFramesGated = 0;
    _txPrerollFlushes = 0;
    _txPrerollFrames = 0;
  }

  void _logMusicHealth() {
    if (!state.isSharingSystemAudio) return;
    final dropouts = _musicMixer.dropouts;
    final trims = _musicMixer.trims;
    final floods = _musicMixer.floods;
    if (dropouts == _lastMusicDropouts &&
        trims == _lastMusicTrims &&
        floods == _lastMusicFloods) {
      return;
    }
    _lastMusicDropouts = dropouts;
    _lastMusicTrims = trims;
    _lastMusicFloods = floods;
    Logger.diagnostic(
      'music cast: ${_musicMixer.queuedSamples} samples queued '
      '(cushion ${_musicMixer.prefillSamples}) | dropouts=$dropouts '
      'trims=$trims floods=$floods capOverflows=${_musicMixer.overflowDrops}',
    );
  }

  /// Catches the one silence that isn't the user's fault.
  ///
  /// Playback capture that runs but delivers only zeros is normal — nothing is
  /// playing — and it is also exactly what a device does when its audio policy
  /// refuses to share playback while our call-mode session is open (confirmed
  /// on a Redmi Note 9 Pro / MIUI 12). The capture stream cannot tell those
  /// apart, so the card said "Nothing's playing — go put a song on" to someone
  /// staring at a playing song.
  ///
  /// The tiebreak is what the other app says about itself. Only ever used to
  /// confirm the blocked case: [MediaControl.isOtherMediaPlaying] returns false
  /// both when nothing plays and when we have no notification access, so the
  /// absence of a signal proves nothing and changes nothing.
  Future<void> _checkMusicBlocked() async {
    if (!state.isSharingSystemAudio) return;
    if (_musicBlockedReported || _musicEverAudible) return;
    final silentSince = _musicSilentSince;
    if (silentSince == null) return;
    if (DateTime.now().difference(silentSince) < _musicBlockedAfter) return;
    if (!await MediaControl.isOtherMediaPlaying()) return;
    if (isClosed || !state.isSharingSystemAudio || _musicEverAudible) return;

    _musicBlockedReported = true;
    Logger.diagnostic(
      'music cast: capture silent for ${_musicBlockedAfter.inSeconds}s while '
      'another app reports playing — this device is withholding playback '
      'capture, most likely while our call-mode session is open',
    );
    // Left running rather than torn down: the cast is doing no harm, the user
    // may have a second player that is not capture-protected, and stopping
    // would pause their music — the very complaint this is here to explain.
    if (!_systemAudioMessageController.isClosed) {
      _systemAudioMessageController.add('capture_blocked');
    }
  }

  Future<void> toggleShareSystemAudio() async {
    if (state.isStartingSystemAudio) return;

    // Stopping stays free for the same reason unmuting does — the early
    // return above means only the start path below reaches the gate.
    if (state.isSharingSystemAudio) {
      await _stopSharingSystemAudio(MusicCastStopReason.userRequest);
      return;
    }

    if (!_gate.allows(PremiumFeature.musicPlayback)) {
      Logger.log('Music cast blocked, no entitlement');
      return;
    }

    _sfx.play(SfxEvent.toggle);
    _useFeature(AppFeature.systemAudio);
    emit(state.copyWith(isStartingSystemAudio: true));
    final started = await SystemAudioCapture.start();
    if (isClosed) return;
    if (!started) {
      emit(state.copyWith(isStartingSystemAudio: false));
      return;
    }
    await _musicSub?.cancel();
    _musicSilentSince = DateTime.now();
    _musicEverAudible = false;
    _musicSub = SystemAudioCapture.frames.listen(
      (chunk) {
        _musicMixer.addChunk(chunk);
        final level = MusicMixer.levelOf(chunk);
        if (level >= _kMusicAudibleLevel) {
          _musicSilentSince = null;
          _musicEverAudible = true;
        } else {
          _musicSilentSince ??= DateTime.now();
        }
        if (!_musicLevelController.isClosed &&
            _musicLevelController.hasListener &&
            chunk.isNotEmpty) {
          _musicLevelController.add(level);
        }
      },
      onError: (Object e) {
        // Diagnostic, not [log]: a cast that ends by itself is exactly the
        // thing a release build has to be able to explain afterwards, and
        // `log` is compiled out there.
        Logger.diagnostic('music cast: capture stream error — $e');
        // Confirmed on-device (MIUI): the native side reports this specific
        // code when playback capture delivers zero frames within a few
        // seconds — an OEM restriction while our call-mode session is open,
        // not a transient glitch worth retrying. Stop pretending to cast
        // instead of leaving the "on air" card silently lying forever.
        if (e is! PlatformException) return;
        // 'capture_revoked': the OS took the projection back — the user
        // stopping the share from the status bar, or another app claiming it.
        // Nothing failed, but the capture is gone, and without this the frames
        // simply stopped while the card went on saying ON AIR.
        final reason = switch (e.code) {
          'capture_stalled' => MusicCastStopReason.captureStalled,
          'capture_revoked' => MusicCastStopReason.captureEnded,
          _ => null,
        };
        if (reason == null || !state.isSharingSystemAudio) return;
        unawaited(_stopSharingSystemAudio(reason));
        _sfx.play(SfxEvent.error);
        if (!_systemAudioMessageController.isClosed) {
          _systemAudioMessageController.add('capture_stalled');
        }
      },
    );
    Logger.diagnostic('music cast: started');
    // The outgoing stream is about to carry music, which a speech codec
    // models badly — tell the transport before the first mixed frame goes out.
    _transferRepository.setAudioProfile(AudioProfile.music);
    emit(
      state.copyWith(isSharingSystemAudio: true, isStartingSystemAudio: false),
    );
    unawaited(SystemAudioCapture.setLocalVolume(state.musicGain));
  }

  /// Ends a cast. [reason] is logged because the user-visible symptom of every
  /// path through here is identical — the music stops — and the only report we
  /// could act on is one that says which path ran.
  Future<void> _stopSharingSystemAudio(MusicCastStopReason reason) async {
    Logger.diagnostic(
      'music cast: stopping (${reason.name}) | dropouts=${_musicMixer.dropouts} '
      'trims=${_musicMixer.trims} floods=${_musicMixer.floods}',
    );
    _sfx.play(SfxEvent.toggle);
    await _musicSub?.cancel();
    _musicSub = null;
    _musicMixer.clear();
    _musicSilentSince = null;
    _musicEverAudible = false;
    _musicBlockedReported = false;
    _transferRepository.setAudioProfile(AudioProfile.voice);
    await SystemAudioCapture.stop();
    // AudioPlaybackCapture never touches the source app, so without this the
    // music the user just "stopped" keeps playing on their own speaker.
    // Silent no-op if the user hasn't granted Notification access.
    //
    // This is also the one call in the app that can pause someone's music
    // player outright, so it is worth being able to point at it in a log when
    // a user reports exactly that happening on its own.
    Logger.diagnostic('music cast: pausing other media');
    unawaited(MediaControl.pauseOtherMedia());
    if (!_musicLevelController.isClosed) _musicLevelController.add(0);
    if (!isClosed) emit(state.copyWith(isSharingSystemAudio: false));
  }

  Future<void> setMusicGain(double gain) async {
    _useFeature(AppFeature.musicGain);
    emit(state.copyWith(musicGain: gain.clamp(0.0, 1.0)));
    if (state.isSharingSystemAudio) {
      unawaited(SystemAudioCapture.setLocalVolume(state.musicGain));
    }
    await _settingsRepository.setMusicGain(state.musicGain);
  }

  void _onPacketReceived(WakiPacket packet) {
    // Self-filter: needed for WiFi (broadcast loops our own packets back to
    // us). Harmless no-op for point-to-point Bluetooth, where a peer's id
    // can never equal our own.
    //
    // Matched on the device id rather than our address: a phone on two
    // interfaces receives its own echo from whichever of its addresses the
    // packet went out by, which is not necessarily the one localId holds.
    if (packet.senderId == _identity.id) return;

    switch (packet) {
      case PresencePacket():
        _noteAudibility(packet);
        _updateUser(
          packet.senderId,
          packet.senderName,
          packet.isTalking,
          packet.role,
        );
      case AudioPacket():
        // Audio carries no role — the roster keeps whatever this peer last
        // announced (see [ChannelRoster.upsert]).
        _updateUser(
          packet.senderId,
          packet.senderName,
          true,
          SessionRole.unknown,
        );
        try {
          // A frame rebuilt from this packet's in-band FEC copy goes in first,
          // at the sequence it was lost from. Order is the whole point: fed in
          // this order the jitter buffer sees an unbroken run and never
          // conceals the gap, which is what a lost packet used to sound like.
          final recovered = packet.recoveredSamples;
          if (recovered != null) {
            _audioEngine.playReceived(
              recovered,
              packet.seq - 1,
              packet.senderId,
            );
          }
          _audioEngine.playReceived(
            packet.samples,
            packet.seq,
            packet.senderId,
          );
        } catch (e) {
          Logger.log('Playback error: $e');
        }
    }
  }

  /// Grades the link from what the transport has counted since the last tick.
  ///
  /// Diffed rather than read absolutely: [TransportStats] counters are
  /// cumulative for the session, so the rate over this 2 s window is the
  /// difference from the previous sample. A session that shed packets early
  /// and has been clean for ten minutes must not still be reporting weak.
  void _gradeLink() {
    if (isClosed) return;
    final now = _transferRepository.stats;
    final previous = _lastStats;
    _lastStats = now;

    final quality = const LinkQualityGrader().grade(
      LinkSignals(
        health: state.connectionHealth,
        sendFailing: now.sendFailing,
        unheardByPeers: state.unheardByPeers,
        unicastUnconfirmed: now.unicastUnconfirmed,
        rtt: now.rtt,
        staleEpochDrops: now.staleEpochDrops - previous.staleEpochDrops,
        duplicateRouteDrops:
            now.duplicateRouteDrops - previous.duplicateRouteDrops,
        blockedSends: now.blockedSends - previous.blockedSends,
        // The roster, not the transport's peer map: Bluetooth and the guest
        // link report no peers at all (TransportStats.none), and grading those
        // as an empty channel would peg every point-to-point session at good.
        hasPeers: state.activeUsers.isNotEmpty,
      ),
    );
    if (quality != state.linkQuality) {
      Logger.diagnostic(
        'link quality: ${state.linkQuality.name} → ${quality.name}',
      );
      emit(state.copyWith(linkQuality: quality));
    }
  }

  /// Previous [TransportStats] sample, so the counters can be diffed.
  TransportStats _lastStats = TransportStats.none;

  /// Records what a peer says about whether it can hear us.
  ///
  /// A null [PresencePacket.heardIds] is silence, not a denial — it comes from
  /// a build that predates the field and from every point-to-point transport —
  /// so it neither confirms nor refutes anything and is skipped entirely.
  /// Anything else is an answer, and one peer hearing us is enough: this asks
  /// "is my voice reaching *anybody*", which is the question the user has.
  void _noteAudibility(PresencePacket packet) {
    final heard = packet.heardIds;
    if (heard == null) return;
    if (!heard.contains(_identity.id)) return;
    _lastHeardByPeerAt = DateTime.now();
    _unheardSince = null;
    if (state.unheardByPeers) {
      Logger.diagnostic('transmit: peers can hear us again');
      emit(state.copyWith(unheardByPeers: false));
    }
  }

  /// Notices that the people we can hear cannot hear us.
  ///
  /// This is the state the whole bug report came down to: after a screen-off
  /// cycle on a hotspot link, one phone kept receiving perfectly while nothing
  /// it sent arrived — and its own troubleshooting sheet reported four green
  /// checks, because every check it had was about receiving.
  ///
  /// Graded only while there is somebody in the roster whose presence carries
  /// an opinion. An empty channel says nothing about audibility, and neither
  /// does a peer on an older build.
  void _checkAudibility() {
    if (!state.isReady || state.activeUsers.isEmpty) {
      // An empty channel is not evidence of anything, and the confirmation
      // clock goes with it: a peer arriving after a long gap has not had a
      // chance to hear us yet, and grading it against the last person who did
      // would flash a warning at every join.
      _unheardSince = null;
      _lastHeardByPeerAt = null;
      if (state.unheardByPeers) emit(state.copyWith(unheardByPeers: false));
      return;
    }
    // Never heard back at all yet: this is a channel still forming, not a
    // broken one. _lastHeardByPeerAt is set the first time any peer confirms
    // us, and only from then on is its absence evidence of anything.
    final confirmed = _lastHeardByPeerAt;
    if (confirmed == null) return;
    // The stretch is measured from the last confirmation by default, and from
    // an explicit reset (a resume, a manual repair) when there has been one —
    // see where [_unheardSince] is set forward.
    final since = _unheardSince ??= confirmed;
    if (DateTime.now().difference(since) < _unheardAfter) return;

    if (!state.unheardByPeers) {
      Logger.diagnostic(
        'transmit: peers we can hear stopped listing us for '
        '${_unheardAfter.inSeconds}s — our send path is one-way',
      );
      _sfx.play(SfxEvent.error);
      emit(state.copyWith(unheardByPeers: true));
    }
    // Asked on every tick, not just the transition: the transport rate-limits
    // itself, and a repair that didn't take needs another go rather than one
    // attempt and a permanent warning.
    _transferRepository.repairSendPath();
  }

  void _updateUser(String id, String name, bool isTalking, SessionRole role) {
    final update = _roster.upsert(
      state.activeUsers,
      ChannelUser(
        id: id,
        name: name,
        isTalking: isTalking,
        lastSeen: DateTime.now(),
        role: role,
      ),
    );
    switch (update.change) {
      case RosterChange.peerStartedTalking:
        _sfx.play(SfxEvent.rxStart);
      case RosterChange.peerJoined:
        // Someone else is actually here — for Wi-Fi that IS the connection.
        _wifiPairing.connected();
        _sfx.play(SfxEvent.peerJoin);
      case RosterChange.peerLeft || RosterChange.none:
        break;
    }
    emit(state.copyWith(activeUsers: update.users));
  }

  void _broadcastPresence() {
    // Refresh FIRST, unconditionally. This used to sit behind the early return
    // below, which made an empty id self-sealing: no presence went out, and the
    // one thing that could have refilled the id never ran either, so the phone
    // stayed silent for the rest of the session. An address that is missing for
    // a moment — the hotspot host's AP interface between a teardown and a
    // re-host — is exactly when this needs to recover on its own.
    _refreshId();
    // Cheap, and the transport can settle on a side after this cubit was
    // built — a Bluetooth link that reconnects as host, a hotspot join that
    // completed while the channel was already open.
    final role = _transferRepository.sessionRole;
    if (role != state.myRole) emit(state.copyWith(myRole: role));
    if (state.localId.isEmpty) return;
    _transferRepository.sendPresence(state.myName, state.isTransmitting);
  }

  void _refreshId() {
    _getLocalId().then((newId) {
      if (!isClosed && newId != state.localId) {
        emit(state.copyWith(localId: newId));
      }
    });
  }

  void _cleanupStaleUsers() {
    final update = _roster.cleanup(state.activeUsers, DateTime.now());
    if (update.change == RosterChange.peerLeft) {
      _sfx.play(SfxEvent.peerLeave);
    }
    emit(state.copyWith(activeUsers: update.users));
    // Rides the roster tick rather than adding timers of its own — these are
    // all "has this been wrong for a while now?" questions, and 3s is a finer
    // grain than any of their grace periods.
    _checkMicHealth();
    _checkNetwork();
    _checkAudibility();
    _checkAlone();
  }

  /// Notices a microphone that is open but mute.
  ///
  /// The engine reports `isStarted: true` as soon as its stream setup returns,
  /// and that setup swallows its own failures — so a device where the capture
  /// device never actually opened looks identical to a working one. Its
  /// watchdog then restarts the engine every couple of seconds, forever,
  /// while the channel screen shows "MIC LIVE" and the user talks to nobody.
  /// Arriving frames are the only honest evidence, so that's what this grades.
  void _checkMicHealth() {
    if (!state.isReady || !state.hasPermission) return;
    final last = _lastFrameAt;
    if (last == null) return;
    final delivering = DateTime.now().difference(last) < _micSilentAfter;
    if (delivering != state.micDelivering) {
      if (!delivering) {
        Logger.diagnostic(
          'mic: no frames for ${_micSilentAfter.inSeconds}s while started — '
          'reporting a dead microphone',
        );
        _sfx.play(SfxEvent.error);
      }
      emit(state.copyWith(micDelivering: delivering));
    }
  }

  /// Notices that this phone has no address to send from.
  ///
  /// On the IP transports [_onAudioFrame] silently refuses to transmit
  /// without one, which produces the app's most confusing possible state: a
  /// live-looking channel that plays everyone else perfectly while nothing
  /// the user says ever leaves the device. The transmit gate logs it; until
  /// now nothing showed it.
  void _checkNetwork() {
    final needsAddress =
        state.transferMode == TransferMode.wifi ||
        state.transferMode == TransferMode.hotspot;
    final missing =
        needsAddress &&
        state.isReady &&
        (state.localId.isEmpty || state.localId == '0.0.0.0');
    if (!missing) {
      _noAddressSince = null;
      if (state.networkMissing) emit(state.copyWith(networkMissing: false));
      return;
    }
    // A network change legitimately drops the address for a moment — only a
    // gap that outlasts the grace is worth a card.
    final since = _noAddressSince ??= DateTime.now();
    if (DateTime.now().difference(since) < _noAddressGrace) return;
    if (!state.networkMissing) {
      Logger.diagnostic(
        'wifi: no local address for ${_noAddressGrace.inSeconds}s',
      );
      emit(state.copyWith(networkMissing: true));
    }
  }

  /// An empty channel is not a failure — but sitting in one with no idea
  /// whether the app is broken or the other person simply hasn't joined is,
  /// and that's the state this ends.
  void _checkAlone() {
    final readyAt = _readyAt;
    if (readyAt == null) return;
    final alone =
        state.activeUsers.isEmpty &&
        DateTime.now().difference(readyAt) >= _aloneAfter;
    if (alone != state.isAlone) emit(state.copyWith(isAlone: alone));
  }

  Future<void> setVoxMargin(double threshold) async {
    emit(state.copyWith(voxMargin: threshold));
    await _settingsRepository.setVoxMargin(threshold);
  }

  /// Self-mute toggle — silences your mic without leaving the channel (for a
  /// passenger chat, a phone call, a cough). VOX keeps running underneath so
  /// unmuting is instant; this only gates whether an open gate transmits.
  /// Deliberately not persisted: mute is a live, per-moment action that
  /// should never survive into a new session.
  void toggleSelfMute() {
    // Only *entering* mute is gated. An entitlement that lapses mid-session
    // while muted would otherwise leave the user permanently silent with no
    // way out — far worse than giving away one free unmute. The same guard
    // covers the home-widget button, which routes through here (see the
    // WidgetControlAction listener in _start).
    if (!state.isSelfMuted && !_gate.allows(PremiumFeature.selfMute)) {
      Logger.log('Self-mute blocked, no entitlement');
      return;
    }
    _sfx.play(SfxEvent.toggle);
    _useFeature(AppFeature.selfMute);
    emit(state.copyWith(isSelfMuted: !state.isSelfMuted));
  }

  Future<void> setNoiseSuppression(double strength) async {
    _useFeature(AppFeature.noiseSuppression);
    _audioEngine.setNoiseSuppression(strength);
    emit(state.copyWith(noiseSuppression: strength));
    await _settingsRepository.setNoiseSuppression(strength);
  }

  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine engine) async {
    _audioEngine.setNoiseSuppressionEngine(engine);
    emit(state.copyWith(noiseSuppressionEngine: engine));
    await _settingsRepository.setNoiseSuppressionEngine(engine);
  }

  /// Turns the riding preset on or off mid-session.
  ///
  /// Persists only the switch — never the values it implies. The rider's own
  /// slider positions stay exactly where they were, so switching back is a
  /// return to their setup rather than to the factory's, which is what makes
  /// this safe to try at a red light.
  Future<void> setRidingPreset(bool enabled) async {
    _useFeature(AppFeature.ridingPreset);
    await _settingsRepository.setRidingPreset(enabled);
    await applyAudioProfile();
  }

  /// Re-reads the resolved audio profile and pushes it at the running engine.
  ///
  /// The one path by which stored settings reach a live session, so a caller
  /// that changed several of them at once (the riding switch, "reset to
  /// normal") cannot leave the engine agreeing with some and not others.
  ///
  /// Jitter depth is the exception and always waits for the next session — the
  /// playback buffer is built once per route, and rebuilding it under a live
  /// call would cost an audible gap to save a latency nobody asked about.
  Future<void> applyAudioProfile() async {
    final profile = await _settingsRepository.getAudioProfile();
    if (isClosed) return;
    _audioEngine.setNoiseSuppression(profile.noiseSuppression);
    _audioEngine.setNoiseSuppressionEngine(profile.noiseSuppressionEngine);
    _audioEngine.setPlaybackGain(profile.playbackGain);
    emit(
      state.copyWith(
        voxMargin: profile.voxMargin,
        noiseSuppression: profile.noiseSuppression,
        noiseSuppressionEngine: profile.noiseSuppressionEngine,
        ridingPreset: profile.fromPreset,
      ),
    );
  }

  /// Manual "Retry now" action for the connection-health banner — bypasses
  /// any backoff wait and is the only way to recover when auto-reconnect is
  /// turned off.
  void retryNow() => _transferRepository.retryNow();

  Future<void> setAutoReconnectEnabled(bool enabled) async {
    _useFeature(AppFeature.autoReconnect);
    _transferRepository.setAutoReconnectEnabled(enabled);
    await _settingsRepository.setAutoReconnectEnabled(enabled);
  }

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _settingsRepository.setMyName(trimmed);
    emit(state.copyWith(myName: trimmed));
    _broadcastPresence();
  }

  /// Resolves this device's transport-level identity. For WiFi this is the
  /// local IPv4 address, used both for display and to filter out our own
  /// broadcast echo. Bluetooth is point-to-point (no echo to filter, no IP
  /// concept), and its "online" state depends on having an active peer
  /// connection rather than a WiFi address, so it short-circuits to a fixed
  /// non-empty id instead of doing a WiFi lookup that may legitimately fail
  /// (WiFi is commonly off when using Bluetooth mode).
  Future<String> _getLocalId() async {
    if (_modeStore.mode == TransferMode.bluetooth) {
      return _kBluetoothLocalId;
    }
    // Guest links are 1-to-1 data channels — no IP concept and no echo to
    // filter, same reasoning as Bluetooth.
    if (_modeStore.mode == TransferMode.guest) {
      return 'guest-host';
    }
    try {
      final best = LanIpv4.bestLocalAddress(await LanIpv4.addresses());
      if (best != null) return best;
    } catch (e) {
      Logger.log('Could not get local IP: $e');
    }
    return '0.0.0.0';
  }

  /// One row per session, emitted while the state is still readable — before
  /// any of the teardown below has run.
  ///
  /// Skipped entirely when the channel never opened: a screen that failed to
  /// connect is a pairing failure, already reported as such, and counting it
  /// as a zero-second session would drag the duration distribution down with
  /// sessions that never happened. Sessions ended by the OS killing the app
  /// are simply lost — close() doesn't run then, and no amount of
  /// bookkeeping here would change that.
  void _reportSessionEnded() {
    // A Wi-Fi attempt still open means nobody ever joined this channel. That
    // is the transport's signature failure — the two phones ended up on
    // different networks, or one of them has client isolation on — and it is
    // completely invisible from the device's own point of view, which sees a
    // perfectly healthy socket the whole time.
    _wifiPairing.failed(PairStage.discover, PairFailure.discoverTimeout);
    final startedAt = _readyAt;
    if (startedAt == null) return;
    _analytics.track(
      AnalyticsEvent.sessionEnded(
        transport: state.transferMode.analytics,
        duration: DateTime.now().difference(startedAt),
        peersMax: _peersMax,
        txCount: _txCount,
        reason: switch (state) {
          _ when state.startFailed => SessionEndReason.error,
          // isLive, not isHealthy: a session that ended during a quiet repair
          // was almost certainly ended by the user — the degraded rung lasts a
          // few seconds and they were never told about it. Counting those as
          // connection losses would inflate the one number this event exists
          // to measure.
          _ when !state.connectionHealth.isLive =>
            SessionEndReason.connectionLost,
          _ => SessionEndReason.userLeft,
        },
      ),
    );
  }

  @override
  Future<void> close() async {
    WidgetsBinding.instance.removeObserver(this);
    _reportSessionEnded();
    _presenceTimer?.cancel();
    _cleanupTimer?.cancel();
    // The session is over, so the hotspot link no longer needs keeping. A no-op
    // for every transport that never adopted one. Deliberately does not tear
    // the AP down — that stays the bridge screen's call.
    unawaited(_linkKeeper.release());

    // Initiate both cancels synchronously (no events delivered after this
    // line), then tear the transport down BEFORE any await. This close is
    // fire-and-forget from BlocProvider's point of view; if stopConnection
    // ran after the awaits below, a cancel that lags (the UDP listener
    // generator can take seconds to unwind from its retry sleep) would let
    // it fire AFTER the user re-entered the page — invalidating the new
    // session's listener generation and closing its freshly bound sockets.
    // Running it synchronously here means it can only ever affect this
    // session's own generation.
    final frameCancel = _frameSub?.cancel();
    final statusCancel = _statusSub?.cancel();
    final packetCancel = _packetSub?.cancel();
    final linkCancel = _linkSub?.cancel();
    unawaited(linkCancel);
    unawaited(_hotspotLinkSub?.cancel());
    unawaited(_widgetControlSub?.cancel());
    _transferRepository.stopConnection();

    // Session over — drop the keep-alive so the foreground service and its
    // wake/Wi-Fi locks don't outlive the channel and drain the battery.
    unawaited(_keepAlive.stop());

    // No more emits will reach onChange, so the widget has to be told
    // explicitly that the channel closed — otherwise the home screen keeps
    // advertising a live session until the staleness timeout catches it.
    unawaited(
      _homeWidget.publish(
        HomeWidgetSnapshot.idle(
          modeKey: state.transferMode.key,
          callsign: state.myName,
        ),
      ),
    );

    // Leaving the channel ends music sharing too — the capture service must
    // not outlive the session it feeds. Deliberately not routed through
    // [_stopSharingSystemAudio]: this is a teardown, and pausing the user's
    // music player on the way out of a channel is not something they asked for.
    if (state.isSharingSystemAudio) {
      Logger.diagnostic(
        'music cast: stopping (${MusicCastStopReason.leavingChannel.name})',
      );
      unawaited(SystemAudioCapture.stop());
    }
    unawaited(_musicSub?.cancel());
    _musicSub = null;
    unawaited(_musicLevelController.close());
    unawaited(_systemAudioMessageController.close());

    await frameCancel;
    await statusCancel;
    await packetCancel;
    await _audioEngine.dispose();
    return super.close();
  }
}

// ── State ─────────────────────────────────────────────────────────────────────

class WalkieTalkieState extends Equatable {
  final String localId;
  final String myName;
  final bool isTransmitting;
  final bool isSelfMuted;
  final bool hasPermission;
  final double voxMargin;
  final double noiseSuppression;
  final NoiseSuppressionEngine noiseSuppressionEngine;

  /// Whether the three values above came from the riding preset rather than
  /// the rider's own sliders. Presentation needs it to say so — a preset that
  /// silently contradicts a control two taps away is worse than no preset.
  final bool ridingPreset;
  final List<ChannelUser> activeUsers;
  final bool isReady;
  final TransferMode transferMode;

  /// The part this device plays in the link, as announced to everyone else.
  final SessionRole myRole;
  final bool isSharingSystemAudio;
  final bool isStartingSystemAudio;
  final double musicGain;

  /// The active transport's link health — Bluetooth/Guest's 1-to-1 peer
  /// link, or WiFi's UDP socket + liveness watchdog — plus, while
  /// reconnecting, the countdown to the next scheduled attempt.
  final ConnectionHealth connectionHealth;

  /// The channel never finished opening — see [WalkieTalkieCubit._start].
  /// Terminal until the user retries, and the only state in which the page is
  /// genuinely non-functional rather than merely degraded.
  final bool startFailed;

  /// Whether mic frames are actually arriving. Starts true: the mic is
  /// innocent until a stretch of silence proves otherwise, so a healthy
  /// session never flashes a warning while it warms up.
  final bool micDelivering;

  /// IP transports only: this device has no local address, so nothing it
  /// says can leave it.
  final bool networkMissing;

  /// The channel has been open a while with nobody else in it.
  final bool isAlone;

  /// Peers we can hear have reported, consistently, that they cannot hear us.
  ///
  /// The one failure the rest of this state cannot see: everything here is
  /// derived from what arrives, and a device whose outgoing path has died
  /// receives perfectly. Only the other end can tell us, and it does — see
  /// [PresencePacket.heardIds].
  final bool unheardByPeers;

  /// How well the link is carrying voice right now, as one word. Graded on the
  /// presence tick from [LinkQualityGrader]; see it for why this is not a
  /// packet-loss percentage.
  final LinkQuality linkQuality;

  const WalkieTalkieState({
    required this.localId,
    required this.myName,
    required this.isTransmitting,
    required this.isSelfMuted,
    required this.hasPermission,
    required this.voxMargin,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
    required this.ridingPreset,
    required this.activeUsers,
    required this.isReady,
    required this.transferMode,
    required this.myRole,
    required this.isSharingSystemAudio,
    required this.isStartingSystemAudio,
    required this.musicGain,
    required this.connectionHealth,
    required this.startFailed,
    required this.micDelivering,
    required this.networkMissing,
    required this.isAlone,
    required this.unheardByPeers,
    required this.linkQuality,
  });

  factory WalkieTalkieState.initial() => const WalkieTalkieState(
    localId: '',
    myName: '',
    isTransmitting: false,
    isSelfMuted: false,
    hasPermission: true,
    voxMargin: 0.0,
    noiseSuppression: 1.0,
    noiseSuppressionEngine: NoiseSuppressionEngine.spectral,
    ridingPreset: false,
    activeUsers: [],
    isReady: false,
    transferMode: TransferMode.wifi,
    myRole: SessionRole.unknown,
    isSharingSystemAudio: false,
    isStartingSystemAudio: false,
    musicGain: 0.85,
    connectionHealth: ConnectionHealth.healthy(),
    startFailed: false,
    micDelivering: true,
    networkMissing: false,
    isAlone: false,
    unheardByPeers: false,
    linkQuality: LinkQuality.excellent,
  );

  WalkieTalkieState copyWith({
    String? localId,
    String? myName,
    bool? isTransmitting,
    bool? isSelfMuted,
    bool? hasPermission,
    double? voxMargin,
    double? noiseSuppression,
    NoiseSuppressionEngine? noiseSuppressionEngine,
    bool? ridingPreset,
    List<ChannelUser>? activeUsers,
    bool? isReady,
    TransferMode? transferMode,
    SessionRole? myRole,
    bool? isSharingSystemAudio,
    bool? isStartingSystemAudio,
    double? musicGain,
    ConnectionHealth? connectionHealth,
    bool? startFailed,
    bool? micDelivering,
    bool? networkMissing,
    bool? isAlone,
    bool? unheardByPeers,
    LinkQuality? linkQuality,
  }) => WalkieTalkieState(
    localId: localId ?? this.localId,
    myName: myName ?? this.myName,
    isTransmitting: isTransmitting ?? this.isTransmitting,
    isSelfMuted: isSelfMuted ?? this.isSelfMuted,
    hasPermission: hasPermission ?? this.hasPermission,
    voxMargin: voxMargin ?? this.voxMargin,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    noiseSuppressionEngine:
        noiseSuppressionEngine ?? this.noiseSuppressionEngine,
    ridingPreset: ridingPreset ?? this.ridingPreset,
    activeUsers: activeUsers ?? this.activeUsers,
    isReady: isReady ?? this.isReady,
    transferMode: transferMode ?? this.transferMode,
    myRole: myRole ?? this.myRole,
    isSharingSystemAudio: isSharingSystemAudio ?? this.isSharingSystemAudio,
    isStartingSystemAudio: isStartingSystemAudio ?? this.isStartingSystemAudio,
    musicGain: musicGain ?? this.musicGain,
    connectionHealth: connectionHealth ?? this.connectionHealth,
    startFailed: startFailed ?? this.startFailed,
    micDelivering: micDelivering ?? this.micDelivering,
    networkMissing: networkMissing ?? this.networkMissing,
    isAlone: isAlone ?? this.isAlone,
    unheardByPeers: unheardByPeers ?? this.unheardByPeers,
    linkQuality: linkQuality ?? this.linkQuality,
  );

  bool get isSomeoneElseTalking => activeUsers.any((u) => u.isTalking);

  /// True when the user's voice cannot reach anybody, whatever the cause.
  /// The channel can look completely normal in every one of these states,
  /// which is exactly why they need saying out loud.
  bool get isMuteToTheWorld =>
      startFailed ||
      !hasPermission ||
      !micDelivering ||
      networkMissing ||
      unheardByPeers;

  @override
  List<Object?> get props => [
    localId,
    myName,
    isTransmitting,
    isSelfMuted,
    hasPermission,
    voxMargin,
    noiseSuppression,
    noiseSuppressionEngine,
    ridingPreset,
    activeUsers,
    isReady,
    transferMode,
    myRole,
    isSharingSystemAudio,
    isStartingSystemAudio,
    musicGain,
    connectionHealth,
    startFailed,
    micDelivering,
    networkMissing,
    isAlone,
    unheardByPeers,
    linkQuality,
  ];
}

/// Why a music cast ended.
///
/// Every one of these looks the same to the user — the music stops, and on the
/// casting phone [MediaControl.pauseOtherMedia] pauses their player outright —
/// so the reason only exists in the log. Without it a report of "it paused on
/// its own" cannot be told apart from a mis-tap.
enum MusicCastStopReason {
  /// The user pressed stop.
  userRequest,

  /// Playback capture delivered nothing — see [SystemAudioCaptureService].
  captureStalled,

  /// The capture stream closed without an error: the OS revoked the media
  /// projection, or the service was killed.
  captureEnded,

  /// The channel is being left, which ends everything with it.
  leavingChannel,
}
