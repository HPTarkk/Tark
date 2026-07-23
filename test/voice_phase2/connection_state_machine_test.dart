import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/connection_state_machine.dart';
import 'package:tark/feature/voice_diagnostics/domain/voice_diagnostics.dart';

void main() {
  test('start is idempotent and does not create parallel reconnect loops', () {
    final machine = ConnectionStateMachine();

    expect(machine.apply(VoiceConnectionEvent.start).state, VoiceConnectionState.discovering);
    expect(machine.apply(VoiceConnectionEvent.start).state, VoiceConnectionState.discovering);
    expect(machine.reconnectAttempt, 0);
  });

  test('heartbeat timeout degrades before bounded reconnect failure', () {
    final machine = ConnectionStateMachine(maxReconnectAttempts: 2);
    machine.apply(VoiceConnectionEvent.start);
    machine.apply(VoiceConnectionEvent.peerDiscovered);
    machine.apply(VoiceConnectionEvent.connectionEstablished);

    expect(machine.apply(VoiceConnectionEvent.heartbeatTimeout).state, VoiceConnectionState.degraded);
    final firstRetry = machine.apply(VoiceConnectionEvent.heartbeatTimeout);
    expect(firstRetry.state, VoiceConnectionState.reconnecting);
    expect(firstRetry.retryDelay, isNotNull);
    expect(firstRetry.sessionPreserved, isTrue);

    machine.apply(VoiceConnectionEvent.retryTimer);
    final secondRetry = machine.apply(VoiceConnectionEvent.socketClosed, reason: 'socket-closed');
    expect(secondRetry.state, VoiceConnectionState.reconnecting);
    machine.apply(VoiceConnectionEvent.retryTimer);
    final failed = machine.apply(VoiceConnectionEvent.socketClosed, reason: 'socket-closed');
    expect(failed.state, VoiceConnectionState.failed);
    expect(failed.sessionPreserved, isFalse);
  });

  test('successful reconnect preserves session and resets attempt counter', () {
    final machine = ConnectionStateMachine();
    machine.apply(VoiceConnectionEvent.start);
    machine.apply(VoiceConnectionEvent.peerDiscovered);
    machine.apply(VoiceConnectionEvent.connectionEstablished);
    machine.apply(VoiceConnectionEvent.networkChanged, reason: 'ip-changed');
    expect(machine.reconnectAttempt, 1);

    final connected = machine.apply(VoiceConnectionEvent.connectionEstablished);

    expect(connected.state, VoiceConnectionState.connected);
    expect(connected.sessionPreserved, isTrue);
    expect(machine.reconnectAttempt, 0);
    expect(machine.disconnectReason, 'ip-changed');
  });

  test('stop cancels pending reconnect attempts', () {
    final machine = ConnectionStateMachine();
    machine.apply(VoiceConnectionEvent.start);
    machine.apply(VoiceConnectionEvent.peerDiscovered);
    machine.apply(VoiceConnectionEvent.socketClosed);

    expect(machine.apply(VoiceConnectionEvent.stop).state, VoiceConnectionState.disconnected);
    expect(machine.apply(VoiceConnectionEvent.retryTimer).state, VoiceConnectionState.disconnected);
  });
}
