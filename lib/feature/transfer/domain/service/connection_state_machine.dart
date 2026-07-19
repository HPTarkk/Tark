import 'dart:math';

import 'package:equatable/equatable.dart';

import '../../../voice_diagnostics/domain/voice_diagnostics.dart';

enum VoiceConnectionEvent {
  start,
  peerDiscovered,
  connectionEstablished,
  packetReceived,
  heartbeatTimeout,
  socketClosed,
  networkChanged,
  ipChanged,
  headsetDisconnected,
  transportFailed,
  retryTimer,
  fallbackRequested,
  stop,
}

class ConnectionTransition extends Equatable {
  const ConnectionTransition({
    required this.state,
    this.disconnectReason,
    this.reconnectAttempt = 0,
    this.retryDelay,
    this.sessionPreserved = true,
  });

  final VoiceConnectionState state;
  final String? disconnectReason;
  final int reconnectAttempt;
  final Duration? retryDelay;
  final bool sessionPreserved;

  @override
  List<Object?> get props => [
    state,
    disconnectReason,
    reconnectAttempt,
    retryDelay,
    sessionPreserved,
  ];
}

class ConnectionStateMachine {
  ConnectionStateMachine({
    this.maxReconnectAttempts = 5,
    this.baseBackoff = const Duration(milliseconds: 250),
    this.maxBackoff = const Duration(seconds: 8),
    Random? random,
  }) : _random = random ?? Random();

  final int maxReconnectAttempts;
  final Duration baseBackoff;
  final Duration maxBackoff;
  final Random _random;

  VoiceConnectionState _state = VoiceConnectionState.idle;
  int _attempt = 0;
  String? _disconnectReason;
  bool _cancelled = false;

  VoiceConnectionState get state => _state;
  int get reconnectAttempt => _attempt;
  String? get disconnectReason => _disconnectReason;

  ConnectionTransition apply(VoiceConnectionEvent event, {String? reason}) {
    if (event == VoiceConnectionEvent.stop) {
      _cancelled = true;
      _attempt = 0;
      return _set(VoiceConnectionState.disconnected, reason: reason ?? 'stopped');
    }

    if (event == VoiceConnectionEvent.start) {
      if (_state != VoiceConnectionState.idle &&
          _state != VoiceConnectionState.disconnected &&
          _state != VoiceConnectionState.failed) {
        return _current();
      }
      _cancelled = false;
      _attempt = 0;
      return _set(VoiceConnectionState.discovering);
    }

    if (_cancelled) return _current();

    if (event == VoiceConnectionEvent.peerDiscovered &&
        (_state == VoiceConnectionState.discovering ||
            _state == VoiceConnectionState.reconnecting)) {
      return _set(VoiceConnectionState.connecting);
    }

    if (event == VoiceConnectionEvent.connectionEstablished &&
        (_state == VoiceConnectionState.connecting ||
            _state == VoiceConnectionState.authenticating ||
            _state == VoiceConnectionState.reconnecting ||
            _state == VoiceConnectionState.switchingTransport)) {
      _attempt = 0;
      return _set(VoiceConnectionState.connected);
    }

    if (event == VoiceConnectionEvent.packetReceived) {
      if (_state == VoiceConnectionState.degraded ||
          _state == VoiceConnectionState.reconnecting) {
        _attempt = 0;
        return _set(VoiceConnectionState.connected);
      }
      if (_state == VoiceConnectionState.connected) return _current();
    }

    if (event == VoiceConnectionEvent.heartbeatTimeout) {
      if (_state == VoiceConnectionState.connected) {
        return _set(
          VoiceConnectionState.degraded,
          reason: reason ?? 'heartbeat-timeout',
        );
      }
      if (_state == VoiceConnectionState.degraded) {
        return _scheduleReconnect(reason ?? 'heartbeat-timeout');
      }
    }

    if ((event == VoiceConnectionEvent.socketClosed ||
            event == VoiceConnectionEvent.networkChanged ||
            event == VoiceConnectionEvent.ipChanged ||
            event == VoiceConnectionEvent.transportFailed) &&
        _state != VoiceConnectionState.idle &&
        _state != VoiceConnectionState.disconnected &&
        _state != VoiceConnectionState.failed) {
      return _scheduleReconnect(reason ?? event.name);
    }

    if (event == VoiceConnectionEvent.retryTimer &&
        _state == VoiceConnectionState.reconnecting) {
      return _set(VoiceConnectionState.connecting, reason: _disconnectReason);
    }

    if (event == VoiceConnectionEvent.fallbackRequested &&
        (_state == VoiceConnectionState.connected ||
            _state == VoiceConnectionState.degraded ||
            _state == VoiceConnectionState.reconnecting)) {
      return _set(
        VoiceConnectionState.switchingTransport,
        reason: reason ?? 'fallback-requested',
      );
    }

    if (event == VoiceConnectionEvent.headsetDisconnected &&
        _state == VoiceConnectionState.connected) {
      return _set(
        VoiceConnectionState.degraded,
        reason: reason ?? 'headset-disconnected',
      );
    }

    return _current();
  }

  ConnectionTransition _scheduleReconnect(String reason) {
    if (_attempt >= maxReconnectAttempts) {
      return _set(VoiceConnectionState.failed, reason: reason, sessionPreserved: false);
    }
    _attempt++;
    final exponentialMs = baseBackoff.inMilliseconds * (1 << (_attempt - 1));
    final cappedMs = min(exponentialMs, maxBackoff.inMilliseconds);
    final jitterMs = _random.nextInt(max(1, cappedMs ~/ 4));
    _disconnectReason = reason;
    _state = VoiceConnectionState.reconnecting;
    return ConnectionTransition(
      state: _state,
      disconnectReason: _disconnectReason,
      reconnectAttempt: _attempt,
      retryDelay: Duration(milliseconds: cappedMs + jitterMs),
    );
  }

  ConnectionTransition _set(
    VoiceConnectionState next, {
    String? reason,
    bool sessionPreserved = true,
  }) {
    _state = next;
    if (reason != null) _disconnectReason = reason;
    return _current(sessionPreserved: sessionPreserved);
  }

  ConnectionTransition _current({bool sessionPreserved = true}) => ConnectionTransition(
    state: _state,
    disconnectReason: _disconnectReason,
    reconnectAttempt: _attempt,
    sessionPreserved: sessionPreserved,
  );
}
