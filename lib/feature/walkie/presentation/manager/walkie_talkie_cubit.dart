import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/home_widget/home_widget_service.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../transfer/domain/service/hotspot_link_keeper.dart';
import '../../../../core/home_widget/home_widget_snapshot.dart';
import '../../../../core/home_widget/widget_control_channel.dart';
import '../../../../core/settings/noise_suppression_engine.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/lan_ipv4.dart';
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
class WalkieTalkieCubit extends Cubit<WalkieTalkieState> {
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

  StreamSubscription<AudioFrame>? _frameSub;
  StreamSubscription<AudioEngineStatus>? _statusSub;
  StreamSubscription<WakiPacket>? _packetSub;
  StreamSubscription<ConnectionHealth>? _linkSub;
  StreamSubscription<HotspotLinkState>? _hotspotLinkSub;
  StreamSubscription<WidgetControlAction>? _widgetControlSub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;

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
  ) : super(WalkieTalkieState.initial()) {
    _init();
  }

  /// Outgoing mic frames, exposed for audio-rate widgets (visualizer, VOX
  /// meter) so presentation never touches the audio feature directly.
  Stream<AudioFrame> get frames => _audioEngine.frames;

  /// Incoming channel audio, for the visualizer while someone else is talking.
  Stream<AudioFrame> get receivedFrames => _audioEngine.receivedFrames;

  Future<void> _init() async {
    final voxThreshold = await _settingsRepository.getVoxThreshold();
    final noiseSuppression = await _settingsRepository.getNoiseSuppression();
    final noiseSuppressionEngine = await _settingsRepository
        .getNoiseSuppressionEngine();
    final musicGain = await _settingsRepository.getMusicGain();

    // The page can be exited while _init is still awaiting (fast back-out).
    // close() has then already run, so bail instead of resurrecting
    // subscriptions and timers nobody will ever cancel.
    if (isClosed) return;

    _audioEngine.setNoiseSuppression(noiseSuppression);
    _audioEngine.setNoiseSuppressionEngine(noiseSuppressionEngine);
    // Attached before start() so no status event can fire and be missed —
    // the controller is a plain broadcast stream, not a replay one.
    _statusSub = _audioEngine.status.listen((status) {
      if (!isClosed && status.hasPermission != state.hasPermission) {
        if (state.hasPermission && !status.hasPermission) {
          _sfx.play(SfxEvent.error);
        }
        emit(state.copyWith(hasPermission: status.hasPermission));
      }
    });

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
        voxThreshold: voxThreshold,
        noiseSuppression: noiseSuppression,
        noiseSuppressionEngine: noiseSuppressionEngine,
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

    _frameSub = _audioEngine.frames.listen(
      _onAudioFrame,
      onError: (Object e) => Logger.log('AudioFrame error: $e'),
    );

    _packetSub = _transferRepository.startListening().listen(
      _onPacketReceived,
      onError: (Object e) => Logger.log('Packet error: $e'),
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
    _linkSub = _transferRepository.connect().listen(_applyHealth);

    // The hotspot link underneath the transport, which has its own failure
    // modes the sockets cannot see: a joiner the OS pulled off the AP, or a
    // host whose AP came back under a new random SSID the peer has no way to
    // learn. Nothing subscribed to this during a live session before, so those
    // were invisible — the call simply went quiet and stayed quiet. Only the
    // bad news is mapped here; "up" is left to the transport, which knows the
    // difference between a link being back and traffic actually flowing again.
    _hotspotLinkSub = _linkKeeper.states.listen((link) {
      if (isClosed) return;
      switch (link) {
        case HotspotLinkState.recovering:
          _applyHealth(const ConnectionHealth.reconnecting());
        case HotspotLinkState.lost:
          _applyHealth(const ConnectionHealth.down());
        case HotspotLinkState.up || HotspotLinkState.idle:
          break;
      }
    }, onError: (Object e) => Logger.log('Hotspot link state error: $e'));

    // MUTE on the home-screen widget, pressed while the app is in the
    // background. Scoped to the live cubit on purpose: no session, nothing
    // subscribed, so a stale widget button can't mute a channel that the
    // user has already left.
    _widgetControlSub = _widgetControl.actions.listen((action) {
      if (isClosed) return;
      if (action == WidgetControlAction.toggleMute) toggleSelfMute();
    });

    _presenceTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _broadcastPresence();
      // Keeps the widget's "last published" timestamp advancing while the
      // session is live but unchanging. onChange alone can go quiet for
      // minutes (nobody talking, roster steady), and the native side demotes
      // state it hasn't heard about to "idle". publish() throttles this down
      // to one actual write every 30s.
      unawaited(_homeWidget.publish(_widgetSnapshot(state)));
    });
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _cleanupStaleUsers(),
    );

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
    final wasHealthy = state.connectionHealth.isHealthy;
    emit(state.copyWith(connectionHealth: health));
    if (wasHealthy && !health.isHealthy) {
      _sfx.play(SfxEvent.linkLost);
    } else if (!wasHealthy && health.isHealthy) {
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
  }

  HomeWidgetSnapshot _widgetSnapshot(WalkieTalkieState s) {
    // Same precedence the on-screen scope pill uses (see VisualizerSection),
    // so the widget and the channel page never disagree about what's
    // happening — with link health on top, since a dropped link makes every
    // other state a lie.
    final session = switch (s) {
      _ when !s.isReady => HomeWidgetSession.connecting,
      _ when s.connectionHealth.status == ConnectionHealthStatus.down =>
        HomeWidgetSession.down,
      _ when s.connectionHealth.status == ConnectionHealthStatus.reconnecting =>
        HomeWidgetSession.reconnecting,
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

  // Hangover + pre-roll VOX shaping — see [VoxGate] for the why.
  final VoxGate _voxGate = VoxGate();
  bool _prevVoiceOpen = false;

  /// Starts true so the first frame with no address reports the gate closing.
  bool _prevIsOnline = true;

  // Roster bookkeeping (join/leave/talk-timeout) — see [ChannelRoster].
  final ChannelRoster _roster = const ChannelRoster();

  // System-audio (music) sharing: capture chunks queue up in the mixer,
  // which re-cuts them onto the mic's 20 ms frame grid — see [MusicMixer].
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
    final gateOpen = _voxGate.advance(frame.rms, state.voxThreshold);
    final voiceOpen = gateOpen && !state.isSelfMuted;
    if (isOnline && voiceOpen != _prevVoiceOpen) {
      _sfx.play(voiceOpen ? SfxEvent.pttOpen : SfxEvent.pttClose);
      // Light tactile confirmation that the channel just keyed up — only on
      // open, not close, so a run of short words doesn't buzz repeatedly.
      if (voiceOpen) unawaited(HapticFeedback.lightImpact());
    }
    _prevVoiceOpen = voiceOpen;
    final sharingMusic = state.isSharingSystemAudio;
    // Music sharing keeps the channel keyed continuously; voice rides on
    // top of it. Without sharing, VOX (with hangover) gates as usual.
    final isTransmitting =
        _audioEngine.currentStatus.hasPermission &&
        isOnline &&
        (voiceOpen || sharingMusic);

    if (isTransmitting) {
      final buffered = _voxGate.drainPreroll();
      if (voiceOpen && !state.isTransmitting) {
        // Gate just opened — flush the pre-roll so the word onset survives.
        for (final samples in buffered) {
          _transferRepository.sendAudio(
            _audioEngine.processForTransmit(samples, state.voxThreshold),
            state.myName,
          );
        }
      }
      var outgoing = voiceOpen
          ? _audioEngine.processForTransmit(frame.samples, state.voxThreshold)
          : List<double>.filled(frame.samples.length, 0.0);
      if (sharingMusic) {
        outgoing = _musicMixer.mix(outgoing, state.musicGain);
      }
      _transferRepository.sendAudio(outgoing, state.myName);
    } else {
      _voxGate.bufferWhileClosed(frame.samples);
    }

    if (isTransmitting != state.isTransmitting) {
      emit(state.copyWith(isTransmitting: isTransmitting));
    }
  }

  Future<void> toggleShareSystemAudio() async {
    if (state.isStartingSystemAudio) return;

    if (state.isSharingSystemAudio) {
      await _stopSharingSystemAudio();
      return;
    }

    _sfx.play(SfxEvent.toggle);
    emit(state.copyWith(isStartingSystemAudio: true));
    final started = await SystemAudioCapture.start();
    if (isClosed) return;
    if (!started) {
      emit(state.copyWith(isStartingSystemAudio: false));
      return;
    }
    await _musicSub?.cancel();
    _musicSub = SystemAudioCapture.frames.listen(
      (chunk) {
        _musicMixer.addChunk(chunk);
        if (!_musicLevelController.isClosed &&
            _musicLevelController.hasListener &&
            chunk.isNotEmpty) {
          _musicLevelController.add(MusicMixer.levelOf(chunk));
        }
      },
      onError: (Object e) {
        Logger.log('System audio stream error: $e');
        // Confirmed on-device (MIUI): the native side reports this specific
        // code when playback capture delivers zero frames within a few
        // seconds — an OEM restriction while our call-mode session is open,
        // not a transient glitch worth retrying. Stop pretending to cast
        // instead of leaving the "on air" card silently lying forever.
        if (e is PlatformException && e.code == 'capture_stalled') {
          unawaited(_stopSharingSystemAudio());
          _sfx.play(SfxEvent.error);
          if (!_systemAudioMessageController.isClosed) {
            _systemAudioMessageController.add('capture_stalled');
          }
        }
      },
    );
    emit(
      state.copyWith(isSharingSystemAudio: true, isStartingSystemAudio: false),
    );
    unawaited(SystemAudioCapture.setLocalVolume(state.musicGain));
  }

  Future<void> _stopSharingSystemAudio() async {
    _sfx.play(SfxEvent.toggle);
    await _musicSub?.cancel();
    _musicSub = null;
    _musicMixer.clear();
    await SystemAudioCapture.stop();
    // AudioPlaybackCapture never touches the source app, so without this the
    // music the user just "stopped" keeps playing on their own speaker.
    // Silent no-op if the user hasn't granted Notification access.
    unawaited(MediaControl.pauseOtherMedia());
    if (!_musicLevelController.isClosed) _musicLevelController.add(0);
    if (!isClosed) emit(state.copyWith(isSharingSystemAudio: false));
  }

  Future<void> setMusicGain(double gain) async {
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
  }

  Future<void> setVoxThreshold(double threshold) async {
    emit(state.copyWith(voxThreshold: threshold));
    await _settingsRepository.setVoxThreshold(threshold);
  }

  /// Self-mute toggle — silences your mic without leaving the channel (for a
  /// passenger chat, a phone call, a cough). VOX keeps running underneath so
  /// unmuting is instant; this only gates whether an open gate transmits.
  /// Deliberately not persisted: mute is a live, per-moment action that
  /// should never survive into a new session.
  void toggleSelfMute() {
    _sfx.play(SfxEvent.toggle);
    emit(state.copyWith(isSelfMuted: !state.isSelfMuted));
  }

  Future<void> setNoiseSuppression(double strength) async {
    _audioEngine.setNoiseSuppression(strength);
    emit(state.copyWith(noiseSuppression: strength));
    await _settingsRepository.setNoiseSuppression(strength);
  }

  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine engine) async {
    _audioEngine.setNoiseSuppressionEngine(engine);
    emit(state.copyWith(noiseSuppressionEngine: engine));
    await _settingsRepository.setNoiseSuppressionEngine(engine);
  }

  /// Manual "Retry now" action for the connection-health banner — bypasses
  /// any backoff wait and is the only way to recover when auto-reconnect is
  /// turned off.
  void retryNow() => _transferRepository.retryNow();

  Future<void> setAutoReconnectEnabled(bool enabled) async {
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

  @override
  Future<void> close() async {
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
    // not outlive the session it feeds.
    if (state.isSharingSystemAudio) {
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
  final double voxThreshold;
  final double noiseSuppression;
  final NoiseSuppressionEngine noiseSuppressionEngine;
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

  const WalkieTalkieState({
    required this.localId,
    required this.myName,
    required this.isTransmitting,
    required this.isSelfMuted,
    required this.hasPermission,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
    required this.activeUsers,
    required this.isReady,
    required this.transferMode,
    required this.myRole,
    required this.isSharingSystemAudio,
    required this.isStartingSystemAudio,
    required this.musicGain,
    required this.connectionHealth,
  });

  factory WalkieTalkieState.initial() => const WalkieTalkieState(
    localId: '',
    myName: '',
    isTransmitting: false,
    isSelfMuted: false,
    hasPermission: true,
    voxThreshold: 0.0,
    noiseSuppression: 1.0,
    noiseSuppressionEngine: NoiseSuppressionEngine.spectral,
    activeUsers: [],
    isReady: false,
    transferMode: TransferMode.wifi,
    myRole: SessionRole.unknown,
    isSharingSystemAudio: false,
    isStartingSystemAudio: false,
    musicGain: 0.85,
    connectionHealth: ConnectionHealth.healthy(),
  );

  WalkieTalkieState copyWith({
    String? localId,
    String? myName,
    bool? isTransmitting,
    bool? isSelfMuted,
    bool? hasPermission,
    double? voxThreshold,
    double? noiseSuppression,
    NoiseSuppressionEngine? noiseSuppressionEngine,
    List<ChannelUser>? activeUsers,
    bool? isReady,
    TransferMode? transferMode,
    SessionRole? myRole,
    bool? isSharingSystemAudio,
    bool? isStartingSystemAudio,
    double? musicGain,
    ConnectionHealth? connectionHealth,
  }) => WalkieTalkieState(
    localId: localId ?? this.localId,
    myName: myName ?? this.myName,
    isTransmitting: isTransmitting ?? this.isTransmitting,
    isSelfMuted: isSelfMuted ?? this.isSelfMuted,
    hasPermission: hasPermission ?? this.hasPermission,
    voxThreshold: voxThreshold ?? this.voxThreshold,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    noiseSuppressionEngine:
        noiseSuppressionEngine ?? this.noiseSuppressionEngine,
    activeUsers: activeUsers ?? this.activeUsers,
    isReady: isReady ?? this.isReady,
    transferMode: transferMode ?? this.transferMode,
    myRole: myRole ?? this.myRole,
    isSharingSystemAudio: isSharingSystemAudio ?? this.isSharingSystemAudio,
    isStartingSystemAudio: isStartingSystemAudio ?? this.isStartingSystemAudio,
    musicGain: musicGain ?? this.musicGain,
    connectionHealth: connectionHealth ?? this.connectionHealth,
  );

  bool get isSomeoneElseTalking => activeUsers.any((u) => u.isTalking);

  @override
  List<Object?> get props => [
    localId,
    myName,
    isTransmitting,
    isSelfMuted,
    hasPermission,
    voxThreshold,
    noiseSuppression,
    noiseSuppressionEngine,
    activeUsers,
    isReady,
    transferMode,
    myRole,
    isSharingSystemAudio,
    isStartingSystemAudio,
    musicGain,
    connectionHealth,
  ];
}
