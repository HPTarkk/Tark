import 'dart:async';
import 'dart:collection';

import 'package:audio_io/audio_io.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/utils/logger.dart';
import '../../../audio/data/audio_engine_impl.dart';
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
/// Dart pieces the mobile app uses.
class GuestSessionCubit extends Cubit<GuestSessionState> {
  GuestSessionCubit(this._client) : super(GuestSessionState.initial()) {
    _packetSub = _client.messages.listen((bytes) {
      final packet = _codec.decode(bytes, 'host');
      if (packet == null) return;
      switch (packet) {
        case PresencePacket():
          _hostLastSeen = DateTime.now();
          emit(state.copyWith(
            hostName: packet.senderName,
            hostTalking: packet.isTalking,
          ));
        case AudioPacket():
          _hostLastSeen = DateTime.now();
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
      if (!isClosed) {
        emit(state.copyWith(linkUp: link == GuestLinkState.connected));
      }
    });
  }

  final GuestWebClient _client;
  final AudioEngine _engine = AudioEngineImpl(AudioIo.instance);
  final _codec = WakiPacketCodec();

  StreamSubscription<dynamic>? _packetSub;
  StreamSubscription<dynamic>? _linkSub;
  StreamSubscription<AudioFrame>? _frameSub;
  Timer? _presenceTimer;
  Timer? _staleTimer;
  DateTime _hostLastSeen = DateTime.now();

  static const _voxThreshold = 0.02;
  static const _kHangoverFrames = 35; // 700 ms
  static const _kPrerollFrames = 3;
  final ListQueue<List<double>> _preroll = ListQueue();
  int _hangover = 0;
  int _audioSeq = 0;

  /// Must be called from a user gesture: Safari only unlocks the audio
  /// context (and shows the mic prompt) inside one.
  Future<void> startAudio() async {
    if (state.audioStarted) return;
    emit(state.copyWith(audioStarting: true));
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
    emit(state.copyWith(audioStarted: true, audioStarting: false));
  }

  void _onFrame(AudioFrame frame) {
    if (frame.rms > _voxThreshold) {
      _hangover = _kHangoverFrames;
    } else if (_hangover > 0) {
      _hangover--;
    }
    final isTalking = _hangover > 0 && !state.muted && _client.isOpen;

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
    final processed = _engine.processForTransmit(samples, _voxThreshold);
    _client.send(_codec.encodeAudio(processed, state.myName, _audioSeq++));
  }

  void toggleMute() => emit(state.copyWith(muted: !state.muted));

  @override
  Future<void> close() async {
    _presenceTimer?.cancel();
    _staleTimer?.cancel();
    await _frameSub?.cancel();
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

  const GuestSessionState({
    required this.myName,
    required this.hostName,
    required this.hostTalking,
    required this.isTalking,
    required this.muted,
    required this.linkUp,
    required this.audioStarting,
    required this.audioStarted,
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
      );

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
      ];
}
