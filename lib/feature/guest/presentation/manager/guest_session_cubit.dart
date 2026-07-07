import 'dart:async';
import 'dart:collection';

import 'package:audio_io/audio_io.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio/data/audio_engine_impl.dart';
import '../../../audio/domain/entity/audio_engine_status.dart';
import '../../../audio/domain/entity/audio_frame.dart';
import '../../../audio/domain/service/audio_engine.dart';
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
  GuestSessionCubit(this._client) : super(GuestSessionState.initial()) {
    _loadPrefs();
    _packetSub = _client.messages.listen((bytes) {
      final packet = _codec.decode(bytes, 'host');
      if (packet == null) return;
      switch (packet) {
        case PresencePacket():
          _hostLastSeen = DateTime.now();
          if (!state.hostTalking && packet.isTalking) {
            Sfx.play(SfxEvent.rxStart);
          }
          emit(state.copyWith(
            hostName: packet.senderName,
            hostTalking: packet.isTalking,
          ));
        case AudioPacket():
          _hostLastSeen = DateTime.now();
          if (!state.hostTalking) Sfx.play(SfxEvent.rxStart);
          emit(state.copyWith(
              hostName: packet.senderName, hostTalking: true));
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
        Sfx.play(isUp ? SfxEvent.linkRestored : SfxEvent.linkLost);
      }
    });
  }

  final GuestWebClient _client;
  final AudioEngine _engine = AudioEngineImpl(AudioIo.instance);
  final _codec = WakiPacketCodec();

  StreamSubscription<dynamic>? _packetSub;
  StreamSubscription<dynamic>? _linkSub;
  StreamSubscription<AudioFrame>? _frameSub;
  StreamSubscription<AudioEngineStatus>? _statusSub;
  Timer? _presenceTimer;
  Timer? _staleTimer;
  DateTime _hostLastSeen = DateTime.now();

  static const _kHangoverFrames = 35; // 700 ms
  static const _kPrerollFrames = 3;
  final ListQueue<List<double>> _preroll = ListQueue();
  int _hangover = 0;
  int _audioSeq = 0;

  /// Mic frames, for the visualizer (same audio-rate side stream the walkie
  /// page uses so the UI animates without state emissions).
  Stream<AudioFrame> get frames => _engine.frames;

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (isClosed) return;
    _engine.setNoiseSuppression(
        prefs.getDouble('noise_suppression') ?? state.noiseSuppression);
    emit(state.copyWith(
      myName: prefs.getString('user_name') ?? state.myName,
      voxThreshold: prefs.getDouble('vox_threshold') ?? state.voxThreshold,
      noiseSuppression:
          prefs.getDouble('noise_suppression') ?? state.noiseSuppression,
    ));
  }

  /// Must be called from a user gesture: Safari only unlocks the audio
  /// context (and shows the mic prompt) inside one.
  Future<void> startAudio() async {
    if (state.audioStarted) return;
    emit(state.copyWith(audioStarting: true));

    _statusSub = _engine.status.listen((status) {
      if (!isClosed && status.hasPermission != state.hasPermission) {
        if (state.hasPermission && !status.hasPermission) {
          Sfx.play(SfxEvent.error);
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

    _frameSub = _engine.frames.listen(_onFrame,
        onError: (Object e) => Logger.log('Guest frame error: $e'));
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
    emit(state.copyWith(
        audioStarted: true, audioStarting: false, isReady: true));
    Sfx.play(SfxEvent.channelJoin);
  }

  void _onFrame(AudioFrame frame) {
    if (frame.rms > state.voxThreshold) {
      _hangover = _kHangoverFrames;
    } else if (_hangover > 0) {
      _hangover--;
    }
    final isTalking = _hangover > 0 && !state.muted && _client.isOpen;

    if (isTalking != state.isTalking) {
      Sfx.play(isTalking ? SfxEvent.pttOpen : SfxEvent.pttClose);
    }

    if (isTalking) {
      if (!state.isTalking) {
        for (final buffered in _preroll) {
          _sendAudio(buffered);
        }
      }
      _preroll.clear();
      _sendAudio(frame.samples);
    } else {
      _preroll.addLast(frame.samples);
      while (_preroll.length > _kPrerollFrames) {
        _preroll.removeFirst();
      }
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
    Sfx.play(SfxEvent.toggle);
    emit(state.copyWith(muted: !state.muted));
  }

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    emit(state.copyWith(myName: trimmed));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', trimmed);
    // Let the host see the new name immediately, not on the next tick.
    if (_client.isOpen) {
      _client.send(_codec.encodePresence(trimmed, state.isTalking));
    }
  }

  Future<void> setVoxThreshold(double threshold) async {
    emit(state.copyWith(voxThreshold: threshold));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('vox_threshold', threshold);
  }

  Future<void> setNoiseSuppression(double strength) async {
    _engine.setNoiseSuppression(strength);
    emit(state.copyWith(noiseSuppression: strength));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('noise_suppression', strength);
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
        voxThreshold: 0.025,
        noiseSuppression: 0.6,
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
  }) =>
      GuestSessionState(
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
      ];
}
