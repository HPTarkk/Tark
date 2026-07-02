import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      transferMode: _modeStore.mode,
    ));

    _statusSub = _audioEngine.status.listen((status) {
      if (!isClosed && status.hasPermission != state.hasPermission) {
        emit(state.copyWith(hasPermission: status.hasPermission));
      }
    });

    await _audioEngine.start();
    if (isClosed) return;

    _frameSub = _audioEngine.frames.listen(
      _onAudioFrame,
      onError: (Object e) => Logger.log('AudioFrame error: $e'),
    );

    _packetSub = _transferRepository.startListening().listen(
      _onPacketReceived,
      onError: (Object e) => Logger.log('Packet error: $e'),
    );

    _presenceTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _broadcastPresence());
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _cleanupStaleUsers());

    emit(state.copyWith(isReady: true));
    _broadcastPresence();
  }

  void _onAudioFrame(AudioFrame frame) {
    // Full duplex: TX and RX run independently, same as a phone call. There
    // is no half-duplex gate here — this app has no hardware acoustic echo
    // cancellation (the underlying audio_io/miniaudio stack doesn't expose
    // any), so on speaker playback (vs. headphones) the mic may pick up
    // some of the other side's voice. Headphones avoid this entirely.

    // No network → never mark as transmitting.
    final isOnline =
        state.localId.isNotEmpty && state.localId != '0.0.0.0';
    final isTransmitting = _audioEngine.currentStatus.hasPermission &&
        isOnline &&
        frame.rms > state.voxThreshold;

    if (isTransmitting != state.isTransmitting) {
      emit(state.copyWith(isTransmitting: isTransmitting));
    }

    if (isTransmitting) {
      final processed =
          _audioEngine.processForTransmit(frame.samples, state.voxThreshold);
      _transferRepository.sendAudio(processed, state.myName);
    }
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
      users[idx] = user;
    } else {
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
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
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
    _transferRepository.stopConnection();

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
      ];
}
