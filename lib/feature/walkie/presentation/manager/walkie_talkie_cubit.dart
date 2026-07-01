import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/transfer/transfer_mode_holder.dart';
import '../../../../core/utils/logger.dart';
import '../../../audio/domain/entity/audio_frame.dart';
import '../../../audio/presentation/manager/audio_cubit.dart';
import '../../../transfer/domain/entity/transfer_mode.dart';
import '../../../transfer/domain/repository/transfer_repository.dart';
import '../../../walkie/domain/entity/channel_user.dart';
import '../../../walkie/domain/entity/waki_packet.dart';

/// Placeholder local id used in Bluetooth mode, where there's no IP concept
/// and the peer connection (established before this cubit is even built) is
/// what actually gates transmission — not this id's value. Kept non-empty
/// and distinct from '0.0.0.0' so the WiFi-oriented online check below
/// doesn't misfire.
const _kBluetoothLocalId = 'bluetooth-peer';

@injectable
class WalkieTalkieCubit extends Cubit<WalkieTalkieState> {
  final AudioCubit audioCubit;
  final TransferRepository _transferRepository;

  StreamSubscription<AudioFrame>? _frameSub;
  StreamSubscription<WakiPacket>? _packetSub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;

  WalkieTalkieCubit(this.audioCubit, this._transferRepository)
      : super(WalkieTalkieState.initial()) {
    _init();
  }

  Future<void> _init() async {
    final localId = await _getLocalId();
    final prefs = await SharedPreferences.getInstance();
    final myName =
        prefs.getString('user_name') ?? 'User${localId.split('.').last}';
    final voxThreshold = prefs.getDouble('vox_threshold') ?? state.voxThreshold;

    emit(state.copyWith(localId: localId, myName: myName, voxThreshold: voxThreshold));

    await audioCubit.start();

    _frameSub = audioCubit.frames.listen(
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
    final isTransmitting = audioCubit.state.hasPermission &&
        isOnline &&
        frame.rms > state.voxThreshold;

    if (isTransmitting != state.isTransmitting) {
      emit(state.copyWith(isTransmitting: isTransmitting));
    }

    if (isTransmitting) {
      final processed =
          audioCubit.processForTransmit(frame.samples, state.voxThreshold);
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
          audioCubit.playReceived(packet.samples, packet.seq, packet.senderId);
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
    if (TransferModeHolder.mode == TransferMode.bluetooth) {
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
    await _frameSub?.cancel();
    await _packetSub?.cancel();
    _transferRepository.stopConnection();
    await audioCubit.close();
    return super.close();
  }
}

// ── State ─────────────────────────────────────────────────────────────────────

class WalkieTalkieState extends Equatable {
  final String localId;
  final String myName;
  final bool isTransmitting;
  final double voxThreshold;
  final List<ChannelUser> activeUsers;
  final bool isReady;

  const WalkieTalkieState({
    required this.localId,
    required this.myName,
    required this.isTransmitting,
    required this.voxThreshold,
    required this.activeUsers,
    required this.isReady,
  });

  factory WalkieTalkieState.initial() => const WalkieTalkieState(
        localId: '',
        myName: '',
        isTransmitting: false,
        voxThreshold: 0.025,
        activeUsers: [],
        isReady: false,
      );

  WalkieTalkieState copyWith({
    String? localId,
    String? myName,
    bool? isTransmitting,
    double? voxThreshold,
    List<ChannelUser>? activeUsers,
    bool? isReady,
  }) =>
      WalkieTalkieState(
        localId: localId ?? this.localId,
        myName: myName ?? this.myName,
        isTransmitting: isTransmitting ?? this.isTransmitting,
        voxThreshold: voxThreshold ?? this.voxThreshold,
        activeUsers: activeUsers ?? this.activeUsers,
        isReady: isReady ?? this.isReady,
      );

  bool get isSomeoneElseTalking => activeUsers.any((u) => u.isTalking);

  @override
  List<Object?> get props => [
        localId,
        myName,
        isTransmitting,
        voxThreshold,
        activeUsers,
        isReady,
      ];
}
