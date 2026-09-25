import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_connection_state.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart';
import 'package:tark/feature/transfer/domain/service/bluetooth_link_handoff.dart';

void main() {
  test('the host waits for the other phone to dial in', () async {
    final transport = _FakeTransport();
    final linked = BluetoothLinkHandoff(transport).host();
    await Future<void>.delayed(Duration.zero);
    expect(transport.hosted, 1);
    transport.emit(BluetoothConnectionState.connected);
    expect(await linked, isTrue);
  });

  test('the host gives up when nobody dials in', () async {
    final transport = _FakeTransport();
    final handoff = BluetoothLinkHandoff(
      transport,
      timeout: const Duration(milliseconds: 20),
    );
    expect(await handoff.host(), isFalse);
  });

  test('the joiner re-dials until the host is listening again', () async {
    // The host needs a moment to put its listener back up once the invite's
    // control socket is closed, so the first dial is refused.
    final transport = _FakeTransport()
      ..onDial = (attempt) => attempt == 1
          ? BluetoothConnectionState.error
          : BluetoothConnectionState.connected;
    final handoff = BluetoothLinkHandoff(
      transport,
      retryGap: const Duration(milliseconds: 1),
    );
    expect(await handoff.join('AA:BB'), isTrue);
    expect(transport.dialed, ['AA:BB', 'AA:BB']);
  });

  test('a hung dial is reset before the next one', () async {
    final transport = _FakeTransport()
      ..onDial = (attempt) =>
          attempt == 1 ? null : BluetoothConnectionState.connected;
    final handoff = BluetoothLinkHandoff(
      transport,
      attemptTimeout: const Duration(milliseconds: 10),
      retryGap: const Duration(milliseconds: 1),
    );
    expect(await handoff.join('AA:BB'), isTrue);
    expect(transport.resets, 1);
  });

  test('the joiner stops at the deadline', () async {
    final transport = _FakeTransport()
      ..onDial = (_) => BluetoothConnectionState.error;
    final handoff = BluetoothLinkHandoff(
      transport,
      timeout: const Duration(milliseconds: 30),
      retryGap: const Duration(milliseconds: 5),
    );
    expect(await handoff.join('AA:BB'), isFalse);
  });
}

class _FakeTransport implements BluetoothTransport {
  final _states = StreamController<BluetoothConnectionState>.broadcast();
  BluetoothConnectionState _current = BluetoothConnectionState.disconnected;
  BluetoothConnectionState? Function(int attempt) onDial = (_) => null;
  int hosted = 0;
  int resets = 0;
  final dialed = <String>[];

  void emit(BluetoothConnectionState state) {
    _current = state;
    _states.add(state);
  }

  @override
  Stream<BluetoothConnectionState> get connectionState => _states.stream;

  @override
  BluetoothConnectionState get currentConnectionState => _current;

  @override
  Future<void> startHosting() async {
    hosted++;
    emit(BluetoothConnectionState.hosting);
  }

  @override
  Future<void> connectToHost(BluetoothPeer peer) async {
    dialed.add(peer.id);
    final outcome = onDial(dialed.length);
    if (outcome != null) {
      scheduleMicrotask(() => emit(outcome));
    }
  }

  @override
  void reset() {
    resets++;
    emit(BluetoothConnectionState.disconnected);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
