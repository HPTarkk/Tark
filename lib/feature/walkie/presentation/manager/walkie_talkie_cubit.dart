import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_io/audio_io.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/utils/logger.dart';
import '../../../transfer/domain/repository/transfer_repository.dart';
import '../../../walkie/domain/entity/channel_user.dart';
import '../../../walkie/domain/entity/waki_packet.dart';

// A remote audio packet arriving within this window suppresses local TX,
// preventing the microphone from picking up speaker output and creating noise.
const _kHalfDuplexGateMs = 600;

@injectable
class WalkieTalkieCubit extends Cubit<WalkieTalkieState> {
  final AudioIo _audioIo;
  final TransferRepository _transferRepository;

  StreamSubscription<List<double>>? _inputSub;
  StreamSubscription<WakiPacket>? _packetSub;
  Timer? _presenceTimer;
  Timer? _cleanupTimer;

  // Tracks when the last remote audio packet was received so we can gate
  // local TX and avoid microphone→speaker echo feedback (the "noise" bug).
  DateTime? _lastRemoteAudioAt;

  WalkieTalkieCubit(this._audioIo, this._transferRepository)
      : super(WalkieTalkieState.initial()) {
    _init();
  }

  Future<void> _init() async {
    final localIp = await _getLocalIp();
    final prefs = await SharedPreferences.getInstance();
    final myName =
        prefs.getString('user_name') ?? 'User${localIp.split('.').last}';
    final voxThreshold =
        prefs.getDouble('vox_threshold') ?? state.voxThreshold;

    emit(state.copyWith(
        localIp: localIp, myName: myName, voxThreshold: voxThreshold));

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      emit(state.copyWith(hasPermission: false));
      return;
    }

    try {
      await _audioIo.stop();
      await _audioIo.requestLatency(AudioIoLatency.Balanced);
      await _audioIo.start();
    } catch (e) {
      Logger.log('AudioIo start error: $e');
    }

    _inputSub =
        _audioIo.input.listen(_onAudioInput, onError: (e) => Logger.log(e));

    _packetSub = _transferRepository
        .startListening()
        .listen(_onPacketReceived, onError: (e) => Logger.log(e));

    _presenceTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _broadcastPresence(),
    );

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _cleanupStaleUsers(),
    );

    emit(state.copyWith(isReady: true));
    _broadcastPresence();
  }

  void _onAudioInput(List<double> samples) {
    final rms = _calculateRms(samples);

    // Half-duplex gate: suppress local TX when remote audio arrived recently.
    // This prevents the mic from picking up speaker output and looping noise.
    final receivingAudio = _lastRemoteAudioAt != null &&
        DateTime.now().difference(_lastRemoteAudioAt!).inMilliseconds <
            _kHalfDuplexGateMs;

    // No network → never mark as transmitting (avoids stale TX badge when offline).
    final isOnline = state.localIp.isNotEmpty && state.localIp != '0.0.0.0';
    final isTransmitting =
        isOnline && rms > state.voxThreshold && !receivingAudio;

    emit(state.copyWith(
      currentRms: rms,
      currentSamples: samples,
      isTransmitting: isTransmitting,
    ));

    if (isTransmitting) {
      _transferRepository.sendAudio(samples, state.myName);
    }
  }

  void _onPacketReceived(WakiPacket packet) {
    if (packet.senderIp == state.localIp) return;

    switch (packet) {
      case PresencePacket():
        _updateUser(packet.senderIp, packet.senderName, packet.isTalking);
      case AudioPacket():
        _lastRemoteAudioAt = DateTime.now();
        _updateUser(packet.senderIp, packet.senderName, true);
        try {
          _audioIo.output.add(packet.samples);
        } catch (e) {
          Logger.log('Playback error: $e');
        }
    }
  }

  void _updateUser(String ip, String name, bool isTalking) {
    final users = List<ChannelUser>.from(state.activeUsers);
    final idx = users.indexWhere((u) => u.ip == ip);
    final user = ChannelUser(
      ip: ip,
      name: name,
      isTalking: isTalking,
      lastSeen: DateTime.now(),
    );
    if (idx >= 0) {
      users[idx] = user;
    } else {
      users.add(user);
    }
    emit(state.copyWith(activeUsers: users));
  }

  void _broadcastPresence() {
    if (state.localIp.isEmpty) return;
    _transferRepository.sendPresence(state.myName, state.isTransmitting);
    _refreshIp();
  }

  void _refreshIp() {
    _getLocalIp().then((newIp) {
      if (!isClosed && newIp != state.localIp) {
        emit(state.copyWith(localIp: newIp));
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
        })
        .toList();
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

  double _calculateRms(List<double> samples) {
    if (samples.isEmpty) return 0.0;
    final sum = samples.fold<double>(0.0, (acc, s) => acc + s * s);
    return sqrt(sum / samples.length);
  }

  Future<String> _getLocalIp() async {
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
    _inputSub?.cancel();
    _packetSub?.cancel();
    _transferRepository.stopConnection();
    await _audioIo.stop();
    return super.close();
  }
}

class WalkieTalkieState extends Equatable {
  final String localIp;
  final String myName;
  final bool isTransmitting;
  final double voxThreshold;
  final double currentRms;
  final List<double> currentSamples;
  final List<ChannelUser> activeUsers;
  final bool isReady;
  final bool hasPermission;

  const WalkieTalkieState({
    required this.localIp,
    required this.myName,
    required this.isTransmitting,
    required this.voxThreshold,
    required this.currentRms,
    required this.currentSamples,
    required this.activeUsers,
    required this.isReady,
    required this.hasPermission,
  });

  factory WalkieTalkieState.initial() => const WalkieTalkieState(
        localIp: '',
        myName: '',
        isTransmitting: false,
        voxThreshold: 0.025,
        currentRms: 0.0,
        currentSamples: [],
        activeUsers: [],
        isReady: false,
        hasPermission: true,
      );

  WalkieTalkieState copyWith({
    String? localIp,
    String? myName,
    bool? isTransmitting,
    double? voxThreshold,
    double? currentRms,
    List<double>? currentSamples,
    List<ChannelUser>? activeUsers,
    bool? isReady,
    bool? hasPermission,
  }) =>
      WalkieTalkieState(
        localIp: localIp ?? this.localIp,
        myName: myName ?? this.myName,
        isTransmitting: isTransmitting ?? this.isTransmitting,
        voxThreshold: voxThreshold ?? this.voxThreshold,
        currentRms: currentRms ?? this.currentRms,
        currentSamples: currentSamples ?? this.currentSamples,
        activeUsers: activeUsers ?? this.activeUsers,
        isReady: isReady ?? this.isReady,
        hasPermission: hasPermission ?? this.hasPermission,
      );

  bool get isSomeoneElseTalking => activeUsers.any((u) => u.isTalking);

  @override
  List<Object?> get props => [
        localIp,
        myName,
        isTransmitting,
        voxThreshold,
        currentRms,
        currentSamples,
        activeUsers,
        isReady,
        hasPermission,
      ];
}
