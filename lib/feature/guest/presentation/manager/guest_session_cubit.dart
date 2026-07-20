import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/settings/noise_suppression_engine.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio/domain/entity/audio_engine_status.dart';
import '../../../audio/domain/entity/audio_frame.dart';
import '../../../audio/domain/service/audio_engine.dart';
import '../../../audio/domain/vox_gate.dart';
// Direct file imports (not the transfer barrel) — see GuestWebClient.
import '../../../transfer/data/codec/waki_packet_codec.dart';
import '../../../transfer/domain/entity/guest_link_state.dart';
import '../../../transfer/domain/entity/waki_packet.dart';
import '../../data/guest_web_client.dart';

/// Runs the browser guest's audio session over an established
/// [GuestWebClient] link: mic → VOX (with the same hangover/pre-roll trick
/// as the app) → Opus/PCM packets → data channel, and the reverse into the
/// jitter-buffered playback path. All components are the exact same pure
/// Dart pieces the mobile app uses, so the guest gets the same VOX / noise
/// controls the walkie page has.
class GuestSessionCubit extends Cubit<GuestSessionState> {
  GuestSessionCubit(
    this._client, {
    required AudioEngine engine,
    required SettingsRepository settingsRepository,
    required WakiPacketCodec codec,
    required SfxPlayer sfx,
  }) : _engine = engine,
       _settingsRepository = settingsRepository,
       _codec = codec,
       _sfx = sfx,
       super(GuestSessionState.initial()) {
    _loadPrefs();
    _packetSub = _client.messages.listen((bytes) {
      final packet = _codec.decode(bytes, 'host');
      if (packet == null) return;
      switch (packet) {
        case PresencePacket():
          _hostLastSeen = DateTime.now();
          if (!state.hostTalking && packet.isTalking) {
            _sfx.play(SfxEvent.rxStart);
          }
          emit(
            state.copyWith(
              hostName: packet.senderName,
              hostTalking: packet.isTalking,
            ),
          );
        case AudioPacket():
          _hostLastSeen = DateTime.now();
          if (!state.hostTalking) _sfx.play(SfxEvent.rxStart);
          emit(state.copyWith(hostName: packet.senderName, hostTalking: true));
          try {
            _engine.playReceived(packet.samples, packet.seq, 'host');
          } catch (e) {
            Logger.log('Guest playback error: $e');
          }
      }
    });
    _linkSub = _client.linkState.listen((link) {
      if (isClosed) return;
      final wasUp = state.linkUp;
      final isUp = link == GuestLinkState.connected;
      if (wasUp != isUp) {
        emit(state.copyWith(linkUp: isUp));
        _sfx.play(isUp ? SfxEvent.linkRestored : SfxEvent.linkLost);
        if (isUp) {
          // Clear stale jitter-buffer/decoder state left over from before
          // the drop so playback doesn't pick up mid-buffer or garble the
          // first packets once the host resumes.
          _engine.resetPlayback();
          _codec.resetDecoders();
        }
      }
    });
  }

  final GuestWebClient _client;
  final SettingsRepository _settingsRepository;
  final AudioEngine _engine;
  final WakiPacketCodec _codec;
  final SfxPlayer _sfx;

  StreamSubscription<dynamic>? _packetSub;
  StreamSubscription<dynamic>? _linkSub;
  StreamSubscription<AudioFrame>? _frameSub;
  StreamSubscription<AudioEngineStatus>? _statusSub;
  Timer? _presenceTimer;
  Timer? _staleTimer;
  DateTime _hostLastSeen = DateTime.now();

  // Hangover + pre-roll VOX shaping, shared with the walkie page — see
  // [VoxGate] for the why.
  final VoxGate _voxGate = VoxGate();
  int _audioSeq = 0;

  /// Mic frames, for the visualizer (same audio-rate side stream the walkie
  /// page uses so the UI animates without state emissions).
  Stream<AudioFrame> get frames => _engine.frames;

  Future<void> _loadPrefs() async {
    final storedName = await _settingsRepository.getMyName();
    final voxThreshold = await _settingsRepository.getVoxThreshold();
    final noiseSuppression = await _settingsRepository.getNoiseSuppression();
    final noiseSuppressionEngine = await _settingsRepository
        .getNoiseSuppressionEngine();
    if (isClosed) return;
    _engine.setNoiseSuppression(noiseSuppression);
    _engine.setNoiseSuppressionEngine(noiseSuppressionEngine);
    emit(
      state.copyWith(
        myName: storedName.isEmpty ? state.myName : storedName,
        voxThreshold: voxThreshold,
        noiseSuppression: noiseSuppression,
        noiseSuppressionEngine: noiseSuppressionEngine,
      ),
    );
  }

  /// Must be called from a user gesture: Safari only unlocks the audio
  /// context (and shows the mic prompt) inside one.
  Future<void> startAudio() async {
    if (state.audioStarted) return;
    emit(state.copyWith(audioStarting: true));

    _statusSub = _engine.status.listen((status) {
      if (!isClosed && status.hasPermission != state.hasPermission) {
        if (state.hasPermission && !status.hasPermission) {
          _sfx.play(SfxEvent.error);
        }
        emit(state.copyWith(hasPermission: status.hasPermission));
      }
    });

    try {
      await _engine.start();
    } catch (e) {
      Logger.log('Guest audio start failed: $e');
    }
    if (isClosed) return;

    _frameSub = _engine.frames.listen(
      _onFrame,
      onError: (Object e) => Logger.log('Guest frame error: $e'),
    );
    _presenceTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_client.isOpen) {
        _client.send(_codec.encodePresence(state.myName, state.isTalking));
      }
    });
    _staleTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (state.hostTalking &&
          DateTime.now().difference(_hostLastSeen).inSeconds > 3) {
        emit(state.copyWith(hostTalking: false));
      }
    });
    emit(
      state.copyWith(audioStarted: true, audioStarting: false, isReady: true),
    );
    _sfx.play(SfxEvent.channelJoin);
  }

  void _onFrame(AudioFrame frame) {
    final gateOpen = _voxGate.advance(frame.rms, state.voxThreshold);
    final isTalking = gateOpen && !state.muted && _client.isOpen;

    if (isTalking != state.isTalking) {
      _sfx.play(isTalking ? SfxEvent.pttOpen : SfxEvent.pttClose);
    }

    if (isTalking) {
      final buffered = _voxGate.drainPreroll();
      if (!state.isTalking) {
        // Gate just opened — flush the pre-roll so the word onset survives.
        for (final samples in buffered) {
          _sendAudio(samples);
        }
      }
      _sendAudio(frame.samples);
    } else {
      _voxGate.bufferWhileClosed(frame.samples);
    }

    if (isTalking != state.isTalking) {
      emit(state.copyWith(isTalking: isTalking));
    }
  }

  void _sendAudio(List<double> samples) {
    final processed = _engine.processForTransmit(samples, state.voxThreshold);
    _client.send(_codec.encodeAudio(processed, state.myName, _audioSeq++));
  }

  void toggleMute() {
    _sfx.play(SfxEvent.toggle);
    emit(state.copyWith(muted: !state.muted));
  }

  /// Manual "Retry now" — the client already bounds its own auto-retry
  /// attempts, so this both covers the "auto-retry gave up" case and lets
  /// the user retry immediately without waiting.
  void retryNow() => _client.retryNow();

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    emit(state.copyWith(myName: trimmed));
    await _settingsRepository.setMyName(trimmed);
    // Let the host see the new name immediately, not on the next tick.
    if (_client.isOpen) {
      _client.send(_codec.encodePresence(trimmed, state.isTalking));
    }
  }

  Future<void> setVoxThreshold(double threshold) async {
    emit(state.copyWith(voxThreshold: threshold));
    await _settingsRepository.setVoxThreshold(threshold);
  }

  Future<void> setNoiseSuppression(double strength) async {
    _engine.setNoiseSuppression(strength);
    emit(state.copyWith(noiseSuppression: strength));
    await _settingsRepository.setNoiseSuppression(strength);
  }

  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine engine) async {
    _engine.setNoiseSuppressionEngine(engine);
    emit(state.copyWith(noiseSuppressionEngine: engine));
    await _settingsRepository.setNoiseSuppressionEngine(engine);
  }

  @override
  Future<void> close() async {
    _presenceTimer?.cancel();
    _staleTimer?.cancel();
    await _frameSub?.cancel();
    await _statusSub?.cancel();
    await _packetSub?.cancel();
    await _linkSub?.cancel();
    await _engine.dispose();
    _codec.release();
    return super.close();
  }
}

class GuestSessionState extends Equatable {
  final String myName;
  final String hostName;
  final bool hostTalking;
  final bool isTalking;
  final bool muted;
  final bool linkUp;
  final bool audioStarting;
  final bool audioStarted;
  final bool isReady;
  final bool hasPermission;
  final double voxThreshold;
  final double noiseSuppression;
  final NoiseSuppressionEngine noiseSuppressionEngine;

  const GuestSessionState({
    required this.myName,
    required this.hostName,
    required this.hostTalking,
    required this.isTalking,
    required this.muted,
    required this.linkUp,
    required this.audioStarting,
    required this.audioStarted,
    required this.isReady,
    required this.hasPermission,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
  });

  factory GuestSessionState.initial() => const GuestSessionState(
    myName: 'Guest',
    hostName: '',
    hostTalking: false,
    isTalking: false,
    muted: false,
    linkUp: true,
    audioStarting: false,
    audioStarted: false,
    isReady: false,
    hasPermission: true,
    voxThreshold: 0.0,
    noiseSuppression: 1.0,
    noiseSuppressionEngine: NoiseSuppressionEngine.spectral,
  );

  GuestSessionState copyWith({
    String? myName,
    String? hostName,
    bool? hostTalking,
    bool? isTalking,
    bool? muted,
    bool? linkUp,
    bool? audioStarting,
    bool? audioStarted,
    bool? isReady,
    bool? hasPermission,
    double? voxThreshold,
    double? noiseSuppression,
    NoiseSuppressionEngine? noiseSuppressionEngine,
  }) => GuestSessionState(
    myName: myName ?? this.myName,
    hostName: hostName ?? this.hostName,
    hostTalking: hostTalking ?? this.hostTalking,
    isTalking: isTalking ?? this.isTalking,
    muted: muted ?? this.muted,
    linkUp: linkUp ?? this.linkUp,
    audioStarting: audioStarting ?? this.audioStarting,
    audioStarted: audioStarted ?? this.audioStarted,
    isReady: isReady ?? this.isReady,
    hasPermission: hasPermission ?? this.hasPermission,
    voxThreshold: voxThreshold ?? this.voxThreshold,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    noiseSuppressionEngine: noiseSuppressionEngine ?? this.noiseSuppressionEngine,
  );

  bool get isHostOnline => hostName.isNotEmpty;

  @override
  List<Object?> get props => [
    myName,
    hostName,
    hostTalking,
    isTalking,
    muted,
    linkUp,
    audioStarting,
    audioStarted,
    isReady,
    hasPermission,
    voxThreshold,
    noiseSuppression,
    noiseSuppressionEngine,
  ];
}
