import 'package:equatable/equatable.dart';

enum VoiceConnectionState {
  idle,
  discovering,
  connecting,
  authenticating,
  connected,
  degraded,
  reconnecting,
  switchingTransport,
  disconnected,
  failed,
}

class VoiceAudioDiagnostics extends Equatable {
  const VoiceAudioDiagnostics({
    this.captureSampleRate,
    this.playbackSampleRate,
    this.frameDurationMs,
    this.encodedFrameSizeBytes,
    this.captureStallCount = 0,
    this.playbackUnderrunCount = 0,
    this.playbackOverrunCount = 0,
    this.currentJitterBufferDepthMs,
    this.jitterBufferTargetMs,
    this.jitterBufferLatePacketCount = 0,
    this.jitterBufferDroppedPacketCount = 0,
    this.opusEncodeDurationUs,
    this.opusDecodeDurationUs,
    this.activeInputDevice,
    this.activeOutputDevice,
    this.bluetoothScoState,
    this.androidAudioMode,
  });

  final int? captureSampleRate;
  final int? playbackSampleRate;
  final int? frameDurationMs;
  final int? encodedFrameSizeBytes;
  final int captureStallCount;
  final int playbackUnderrunCount;
  final int playbackOverrunCount;
  final int? currentJitterBufferDepthMs;
  final int? jitterBufferTargetMs;
  final int jitterBufferLatePacketCount;
  final int jitterBufferDroppedPacketCount;
  final int? opusEncodeDurationUs;
  final int? opusDecodeDurationUs;
  final String? activeInputDevice;
  final String? activeOutputDevice;
  final String? bluetoothScoState;
  final String? androidAudioMode;

  @override
  List<Object?> get props => [
    captureSampleRate,
    playbackSampleRate,
    frameDurationMs,
    encodedFrameSizeBytes,
    captureStallCount,
    playbackUnderrunCount,
    playbackOverrunCount,
    currentJitterBufferDepthMs,
    jitterBufferTargetMs,
    jitterBufferLatePacketCount,
    jitterBufferDroppedPacketCount,
    opusEncodeDurationUs,
    opusDecodeDurationUs,
    activeInputDevice,
    activeOutputDevice,
    bluetoothScoState,
    androidAudioMode,
  ];
}

class VoiceNetworkDiagnostics extends Equatable {
  const VoiceNetworkDiagnostics({
    this.currentTransport,
    this.localIp,
    this.peerIp,
    this.networkType,
    this.connectionState = VoiceConnectionState.idle,
    this.lastPacketReceivedMonotonicUs,
    this.lastHeartbeatReceivedMonotonicUs,
    this.estimatedRttUs,
    this.interArrivalJitterUs,
    this.packetCount = 0,
    this.packetLossEstimate,
    this.reconnectCount = 0,
    this.lastReconnectDurationUs,
    this.currentReconnectAttempt = 0,
    this.disconnectReason,
    this.wifiDisconnectCount = 0,
    this.bluetoothDisconnectCount = 0,
    this.socketRebindCount = 0,
    this.transportSwitchCount = 0,
  });

  final String? currentTransport;
  final String? localIp;
  final String? peerIp;
  final String? networkType;
  final VoiceConnectionState connectionState;
  final int? lastPacketReceivedMonotonicUs;
  final int? lastHeartbeatReceivedMonotonicUs;
  final int? estimatedRttUs;
  final int? interArrivalJitterUs;
  final int packetCount;
  final double? packetLossEstimate;
  final int reconnectCount;
  final int? lastReconnectDurationUs;
  final int currentReconnectAttempt;
  final String? disconnectReason;
  final int wifiDisconnectCount;
  final int bluetoothDisconnectCount;
  final int socketRebindCount;
  final int transportSwitchCount;

  @override
  List<Object?> get props => [
    currentTransport,
    localIp,
    peerIp,
    networkType,
    connectionState,
    lastPacketReceivedMonotonicUs,
    lastHeartbeatReceivedMonotonicUs,
    estimatedRttUs,
    interArrivalJitterUs,
    packetCount,
    packetLossEstimate,
    reconnectCount,
    lastReconnectDurationUs,
    currentReconnectAttempt,
    disconnectReason,
    wifiDisconnectCount,
    bluetoothDisconnectCount,
    socketRebindCount,
    transportSwitchCount,
  ];
}

class VoiceSessionDiagnostics extends Equatable {
  const VoiceSessionDiagnostics({
    required this.sessionId,
    required this.roomId,
    required this.peerId,
    this.selectedTransport,
    this.fallbackReason,
    this.sessionAgeUs,
    this.connectionAgeUs,
  });

  final String sessionId;
  final String roomId;
  final String peerId;
  final String? selectedTransport;
  final String? fallbackReason;
  final int? sessionAgeUs;
  final int? connectionAgeUs;

  @override
  List<Object?> get props => [
    sessionId,
    roomId,
    peerId,
    selectedTransport,
    fallbackReason,
    sessionAgeUs,
    connectionAgeUs,
  ];
}

class VoiceDiagnosticsSnapshot extends Equatable {
  const VoiceDiagnosticsSnapshot({
    required this.audio,
    required this.network,
    required this.session,
  });

  final VoiceAudioDiagnostics audio;
  final VoiceNetworkDiagnostics network;
  final VoiceSessionDiagnostics session;

  Map<String, Object?> toPrivacySafeJson({bool includeLocalAddresses = false}) => {
    'audio': {
      'captureSampleRate': audio.captureSampleRate,
      'playbackSampleRate': audio.playbackSampleRate,
      'frameDurationMs': audio.frameDurationMs,
      'encodedFrameSizeBytes': audio.encodedFrameSizeBytes,
      'captureStallCount': audio.captureStallCount,
      'playbackUnderrunCount': audio.playbackUnderrunCount,
      'playbackOverrunCount': audio.playbackOverrunCount,
      'currentJitterBufferDepthMs': audio.currentJitterBufferDepthMs,
      'jitterBufferTargetMs': audio.jitterBufferTargetMs,
      'jitterBufferLatePacketCount': audio.jitterBufferLatePacketCount,
      'jitterBufferDroppedPacketCount': audio.jitterBufferDroppedPacketCount,
      'opusEncodeDurationUs': audio.opusEncodeDurationUs,
      'opusDecodeDurationUs': audio.opusDecodeDurationUs,
      'activeInputDevice': audio.activeInputDevice,
      'activeOutputDevice': audio.activeOutputDevice,
      'bluetoothScoState': audio.bluetoothScoState,
      'androidAudioMode': audio.androidAudioMode,
    },
    'network': {
      'currentTransport': network.currentTransport,
      'localIp': includeLocalAddresses ? network.localIp : _redactIp(network.localIp),
      'peerIp': includeLocalAddresses ? network.peerIp : _redactIp(network.peerIp),
      'networkType': network.networkType,
      'connectionState': network.connectionState.name,
      'estimatedRttUs': network.estimatedRttUs,
      'interArrivalJitterUs': network.interArrivalJitterUs,
      'packetCount': network.packetCount,
      'packetLossEstimate': network.packetLossEstimate,
      'reconnectCount': network.reconnectCount,
      'lastReconnectDurationUs': network.lastReconnectDurationUs,
      'currentReconnectAttempt': network.currentReconnectAttempt,
      'disconnectReason': network.disconnectReason,
      'wifiDisconnectCount': network.wifiDisconnectCount,
      'bluetoothDisconnectCount': network.bluetoothDisconnectCount,
      'socketRebindCount': network.socketRebindCount,
      'transportSwitchCount': network.transportSwitchCount,
    },
    'session': {
      'sessionId': session.sessionId,
      'roomId': session.roomId,
      'peerId': session.peerId,
      'selectedTransport': session.selectedTransport,
      'fallbackReason': session.fallbackReason,
      'sessionAgeUs': session.sessionAgeUs,
      'connectionAgeUs': session.connectionAgeUs,
    },
  };

  static String? _redactIp(String? value) {
    if (value == null || value.isEmpty) return value;
    return value.contains(':') ? 'redacted-ipv6' : 'redacted-ipv4';
  }

  @override
  List<Object?> get props => [audio, network, session];
}
