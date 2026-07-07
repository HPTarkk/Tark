import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/utils/lan_ipv4.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio/api/audio_api.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/channel_user.dart';

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

  StreamSubscription<AudioFrame>? _frameSub;
  StreamSubscription<AudioEngineStatus>? _statusSub;
  StreamSubscription<WakiPacket>? _packetSub;
  StreamSubscription<bool>? _linkSub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;

  WalkieTalkieCubit(this._audioEngine, this._transferRepository, this._modeStore)
      : super(WalkieTalkieState.initial()) {
    _init();
  }

  /// Outgoing mic frames, exposed for audio-rate widgets (visualizer, VOX
  /// meter) so presentation never touches the audio feature directly.
  Stream<AudioFrame> get frames => _audioEngine.frames;

  Future<void> _init() async {
    final localId = await _getLocalId();
    final prefs = await SharedPreferences.getInstance();
    final myName =
        prefs.getString('user_name') ?? 'User${localId.split('.').last}';
    final voxThreshold = prefs.getDouble('vox_threshold') ?? state.voxThreshold;
    final noiseSuppression =
        prefs.getDouble('noise_suppression') ?? state.noiseSuppression;
    final musicGain = prefs.getDouble('music_gain') ?? state.musicGain;

    // The page can be exited while _init is still awaiting (fast back-out).
    // close() has then already run, so bail instead of resurrecting
    // subscriptions and timers nobody will ever cancel.
    if (isClosed) return;

    _audioEngine.setNoiseSuppression(noiseSuppression);
    emit(state.copyWith(
      localId: localId,
      myName: myName,
      voxThreshold: voxThreshold,
      noiseSuppression: noiseSuppression,
      musicGain: musicGain,
      transferMode: _modeStore.mode,
    ));

    _statusSub = _audioEngine.status.listen((status) {
      if (!isClosed && status.hasPermission != state.hasPermission) {
        if (state.hasPermission && !status.hasPermission) {
          Sfx.play(SfxEvent.error);
        }
        emit(state.copyWith(hasPermission: status.hasPermission));
      }
    });

    await _audioEngine.start();
    if (isClosed) return;

    // Keep the CPU + Wi-Fi awake for the whole session so audio and the
    // transport survive the screen going off (the motorcycle case). Android
    // foreground service + wake/Wi-Fi/multicast locks; a no-op elsewhere.
    unawaited(SessionKeepAlive.start());

    _frameSub = _audioEngine.frames.listen(
      _onAudioFrame,
      onError: (Object e) => Logger.log('AudioFrame error: $e'),
    );

    _packetSub = _transferRepository.startListening().listen(
      _onPacketReceived,
      onError: (Object e) => Logger.log('Packet error: $e'),
    );

    // Every transport's connect() stream reflects the same "is the link
    // currently up" signal — for Bluetooth/Guest that's the 1-to-1 peer
    // link, for WiFi it's the UDP socket's bind/rebind lifecycle (see
    // WifiTransferRepositoryImpl's exponential-backoff rebind loop). Either
    // way, a drop means the same "link lost — reconnecting" banner + sound
    // applies, so this is no longer gated to specific transports.
    _linkSub = _transferRepository.connect().listen((connected) {
      if (isClosed) return;
      final wasDown = state.isLinkDown;
      final isDown = !connected;
      if (wasDown != isDown) {
        emit(state.copyWith(isLinkDown: isDown));
        Sfx.play(isDown ? SfxEvent.linkLost : SfxEvent.linkRestored);
      }
    });

    _presenceTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcastPresence());
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _cleanupStaleUsers());

    emit(state.copyWith(isReady: true));
    Sfx.play(SfxEvent.channelJoin);
    _broadcastPresence();
  }

  // VOX shaping. A raw per-frame RMS gate is what made transmission sound
  // choppy: the instant a frame dipped below threshold (every gap between
  // words, every soft syllable) TX cut out, chopping word endings, and the
  // first frame of speech was likewise lost because the gate only opened
  // AFTER the onset frame that tripped it. Two counter-measures:
  //  * hangover — once voice is detected, keep transmitting for a while
  //    after the level drops, so natural pauses don't slice the stream;
  //  * pre-roll — while idle, keep the last few frames; when the gate
  //    opens, send them first so the word onset that opened it is heard.
  static const _kHangoverFrames = 35; // 35 × 20 ms = 700 ms
  static const _kPrerollFrames = 3; // 3 × 20 ms = 60 ms
  final ListQueue<List<double>> _preroll = ListQueue();
  int _hangover = 0;
  bool _prevVoiceOpen = false;

  // System-audio (music) sharing: captured playback arrives as ~100 ms
  // chunks on its own clock and is re-cut to the mic's 20 ms frame grid by
  // buffering through this queue. Capped at 1 s — the two clocks drift, and
  // a runaway queue would turn into pure latency.
  StreamSubscription<List<double>>? _musicSub;
  final ListQueue<double> _musicQueue = ListQueue();
  static const _kMusicQueueMax = 16000; // 1 s at 16 kHz

  // Level of the captured system audio (~10 Hz, one value per capture
  // chunk), for the music-cast equalizer. Same pattern as [frames]: an
  // audio-rate side stream so the UI can animate without state emissions.
  final _musicLevelController = StreamController<double>.broadcast();
  Stream<double> get musicLevels => _musicLevelController.stream;

  // One-shot notices about system-audio sharing (currently just the
  // capture-stalled case below) for the page to show as a toast. Side channel
  // rather than state: it's a transient event, not something to redraw for.
  final _systemAudioMessageController = StreamController<String>.broadcast();
  Stream<String> get systemAudioMessages => _systemAudioMessageController.stream;

  void _onAudioFrame(AudioFrame frame) {
    // Full duplex: TX and RX run independently, same as a phone call. No
    // half-duplex gate — the platform's voice processing (echo cancellation /
    // noise suppression / AGC) is engaged for the session: on Android via the
    // VOICE_COMMUNICATION preset plus explicitly-attached AEC/NS/AGC effects
    // (see AudioSessionHandler.attachEffects), on iOS via AVAudioSession
    // voiceChat. Residual echo can still leak on loudspeaker with weak device
    // AEC; headphones avoid it entirely.

    // No network → never mark as transmitting.
    final isOnline =
        state.localId.isNotEmpty && state.localId != '0.0.0.0';

    if (frame.rms > state.voxThreshold) {
      _hangover = _kHangoverFrames;
    } else if (_hangover > 0) {
      _hangover--;
    }

    final voiceOpen = _hangover > 0;
    if (isOnline && voiceOpen != _prevVoiceOpen) {
      Sfx.play(voiceOpen ? SfxEvent.pttOpen : SfxEvent.pttClose);
      // Light tactile confirmation that the channel just keyed up — only on
      // open, not close, so a run of short words doesn't buzz repeatedly.
      if (voiceOpen) unawaited(HapticFeedback.lightImpact());
    }
    _prevVoiceOpen = voiceOpen;
    final sharingMusic = state.isSharingSystemAudio;
    // Music sharing keeps the channel keyed continuously; voice rides on
    // top of it. Without sharing, VOX (with hangover) gates as usual.
    final isTransmitting = _audioEngine.currentStatus.hasPermission &&
        isOnline &&
        (voiceOpen || sharingMusic);

    if (isTransmitting) {
      if (voiceOpen && !state.isTransmitting) {
        // Gate just opened — flush the pre-roll so the word onset survives.
        for (final buffered in _preroll) {
          _transferRepository.sendAudio(
            _audioEngine.processForTransmit(buffered, state.voxThreshold),
            state.myName,
          );
        }
      }
      _preroll.clear();
      var outgoing = voiceOpen
          ? _audioEngine.processForTransmit(frame.samples, state.voxThreshold)
          : List<double>.filled(frame.samples.length, 0.0);
      if (sharingMusic) outgoing = _mixMusic(outgoing);
      _transferRepository.sendAudio(outgoing, state.myName);
    } else {
      _preroll.addLast(frame.samples);
      while (_preroll.length > _kPrerollFrames) {
        _preroll.removeFirst();
      }
    }

    if (isTransmitting != state.isTransmitting) {
      emit(state.copyWith(isTransmitting: isTransmitting));
    }
  }

  /// Adds up to one frame's worth of captured system audio on top of the
  /// (possibly silent) mic frame. Falls back to the mic-only frame when the
  /// capture queue runs dry (music paused, capture-protected app).
  List<double> _mixMusic(List<double> voice) {
    final gain = state.musicGain;
    final mixed = List<double>.from(voice);
    for (var i = 0; i < mixed.length && _musicQueue.isNotEmpty; i++) {
      mixed[i] =
          (mixed[i] + _musicQueue.removeFirst() * gain).clamp(-1.0, 1.0);
    }
    return mixed;
  }

  Future<void> toggleShareSystemAudio() async {
    if (state.isStartingSystemAudio) return;

    if (state.isSharingSystemAudio) {
      await _stopSharingSystemAudio();
      return;
    }

    Sfx.play(SfxEvent.toggle);
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
        for (final sample in chunk) {
          _musicQueue.addLast(sample);
        }
        while (_musicQueue.length > _kMusicQueueMax) {
          _musicQueue.removeFirst();
        }
        if (!_musicLevelController.isClosed &&
            _musicLevelController.hasListener &&
            chunk.isNotEmpty) {
          var sum = 0.0;
          for (final sample in chunk) {
            sum += sample * sample;
          }
          _musicLevelController.add(sqrt(sum / chunk.length));
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
          Sfx.play(SfxEvent.error);
          if (!_systemAudioMessageController.isClosed) {
            _systemAudioMessageController.add('capture_stalled');
          }
        }
      },
    );
    emit(state.copyWith(
      isSharingSystemAudio: true,
      isStartingSystemAudio: false,
    ));
    unawaited(SystemAudioCapture.setLocalVolume(state.musicGain));
  }

  Future<void> _stopSharingSystemAudio() async {
    Sfx.play(SfxEvent.toggle);
    await _musicSub?.cancel();
    _musicSub = null;
    _musicQueue.clear();
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('music_gain', state.musicGain);
  }

  void _onPacketReceived(WakiPacket packet) {
    // Self-filter: needed for WiFi (broadcast loops our own packets back to
    // us). Harmless no-op for point-to-point Bluetooth, where a peer's id
    // can never equal our own.
    if (packet.senderId == state.localId) return;

    switch (packet) {
      case PresencePacket():
        _updateUser(packet.senderId, packet.senderName, packet.isTalking);
      case AudioPacket():
        _updateUser(packet.senderId, packet.senderName, true);
        try {
          _audioEngine.playReceived(packet.samples, packet.seq, packet.senderId);
        } catch (e) {
          Logger.log('Playback error: $e');
        }
    }
  }

  void _updateUser(String id, String name, bool isTalking) {
    final users = List<ChannelUser>.from(state.activeUsers);
    final idx = users.indexWhere((u) => u.id == id);
    final user =
        ChannelUser(id: id, name: name, isTalking: isTalking, lastSeen: DateTime.now());
    if (idx >= 0) {
      if (!users[idx].isTalking && isTalking) Sfx.play(SfxEvent.rxStart);
      users[idx] = user;
    } else {
      Sfx.play(SfxEvent.peerJoin);
      users.add(user);
    }
    emit(state.copyWith(activeUsers: users));
  }

  void _broadcastPresence() {
    if (state.localId.isEmpty) return;
    _transferRepository.sendPresence(state.myName, state.isTransmitting);
    _refreshId();
  }

  void _refreshId() {
    _getLocalId().then((newId) {
      if (!isClosed && newId != state.localId) {
        emit(state.copyWith(localId: newId));
      }
    });
  }

  void _cleanupStaleUsers() {
    final now = DateTime.now();
    final updated = state.activeUsers
        .where((u) => now.difference(u.lastSeen).inSeconds < 8)
        .map((u) {
      if (now.difference(u.lastSeen).inSeconds > 3 && u.isTalking) {
        return u.copyWith(isTalking: false);
      }
      return u;
    }).toList();
    if (updated.length < state.activeUsers.length) {
      Sfx.play(SfxEvent.peerLeave);
    }
    emit(state.copyWith(activeUsers: updated));
  }

  Future<void> setVoxThreshold(double threshold) async {
    emit(state.copyWith(voxThreshold: threshold));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('vox_threshold', threshold);
  }

  Future<void> setNoiseSuppression(double strength) async {
    _audioEngine.setNoiseSuppression(strength);
    emit(state.copyWith(noiseSuppression: strength));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('noise_suppression', strength);
  }

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', trimmed);
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
    _transferRepository.stopConnection();

    // Session over — drop the keep-alive so the foreground service and its
    // wake/Wi-Fi locks don't outlive the channel and drain the battery.
    unawaited(SessionKeepAlive.stop());

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
  final bool hasPermission;
  final double voxThreshold;
  final double noiseSuppression;
  final List<ChannelUser> activeUsers;
  final bool isReady;
  final TransferMode transferMode;
  final bool isSharingSystemAudio;
  final bool isStartingSystemAudio;
  final double musicGain;

  /// The active transport's link dropped and it's auto-reconnecting —
  /// Bluetooth/Guest's 1-to-1 peer link, or WiFi's UDP socket rebind.
  final bool isLinkDown;

  const WalkieTalkieState({
    required this.localId,
    required this.myName,
    required this.isTransmitting,
    required this.hasPermission,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.activeUsers,
    required this.isReady,
    required this.transferMode,
    required this.isSharingSystemAudio,
    required this.isStartingSystemAudio,
    required this.musicGain,
    required this.isLinkDown,
  });

  factory WalkieTalkieState.initial() => const WalkieTalkieState(
        localId: '',
        myName: '',
        isTransmitting: false,
        hasPermission: true,
        voxThreshold: 0.025,
        noiseSuppression: 0.6,
        activeUsers: [],
        isReady: false,
        transferMode: TransferMode.wifi,
        isSharingSystemAudio: false,
        isStartingSystemAudio: false,
        musicGain: 0.85,
        isLinkDown: false,
      );

  WalkieTalkieState copyWith({
    String? localId,
    String? myName,
    bool? isTransmitting,
    bool? hasPermission,
    double? voxThreshold,
    double? noiseSuppression,
    List<ChannelUser>? activeUsers,
    bool? isReady,
    TransferMode? transferMode,
    bool? isSharingSystemAudio,
    bool? isStartingSystemAudio,
    double? musicGain,
    bool? isLinkDown,
  }) =>
      WalkieTalkieState(
        localId: localId ?? this.localId,
        myName: myName ?? this.myName,
        isTransmitting: isTransmitting ?? this.isTransmitting,
        hasPermission: hasPermission ?? this.hasPermission,
        voxThreshold: voxThreshold ?? this.voxThreshold,
        noiseSuppression: noiseSuppression ?? this.noiseSuppression,
        activeUsers: activeUsers ?? this.activeUsers,
        isReady: isReady ?? this.isReady,
        transferMode: transferMode ?? this.transferMode,
        isSharingSystemAudio:
            isSharingSystemAudio ?? this.isSharingSystemAudio,
        isStartingSystemAudio:
            isStartingSystemAudio ?? this.isStartingSystemAudio,
        musicGain: musicGain ?? this.musicGain,
        isLinkDown: isLinkDown ?? this.isLinkDown,
      );

  bool get isSomeoneElseTalking => activeUsers.any((u) => u.isTalking);

  @override
  List<Object?> get props => [
        localId,
        myName,
        isTransmitting,
        hasPermission,
        voxThreshold,
        noiseSuppression,
        activeUsers,
        isReady,
        transferMode,
        isSharingSystemAudio,
        isStartingSystemAudio,
        musicGain,
        isLinkDown,
      ];
}
