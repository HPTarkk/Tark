import 'dart:async';

import '../../../../core/utils/logger.dart';
import '../entity/bluetooth_connection_state.dart';
import '../entity/bluetooth_peer.dart';
import '../repository/bluetooth_transport.dart';

/// Brings up the Bluetooth audio link between two phones that already know
/// each other, with no screen and no scan.
///
/// A Room invite ends with the two phones joined by a short-lived control
/// socket. When Bluetooth is the chosen connection, that is closed and this
/// opens the real audio link in its place: the phone that showed the invite
/// hosts, and the phone that scanned it dials the address it just reached.
/// The joiner keeps re-dialing for a while because the host needs a moment
/// to put its listener back up after the control socket goes.
final class BluetoothLinkHandoff {
  BluetoothLinkHandoff(
    this._transport, {
    this.timeout = const Duration(seconds: 30),
    this.attemptTimeout = const Duration(seconds: 8),
    this.retryGap = const Duration(milliseconds: 1500),
  });

  final BluetoothTransport _transport;

  /// Longest the whole hand-off may take on either side.
  final Duration timeout;

  /// Longest one dial may take before the joiner tries again.
  final Duration attemptTimeout;

  /// Pause between the joiner's dials.
  final Duration retryGap;

  bool get _connected =>
      _transport.currentConnectionState == BluetoothConnectionState.connected;

  /// Hosts and waits for the other phone to dial in.
  Future<bool> host() async {
    if (_connected) return true;
    Logger.diagnostic('room_bluetooth: host start');
    final connected = _nextConnected(timeout);
    try {
      await _transport.startHosting();
    } catch (e) {
      Logger.diagnostic('room_bluetooth: host failed ${e.runtimeType}');
      unawaited(connected.catchError((Object _) => false));
      return false;
    }
    final ok = await connected;
    Logger.diagnostic('room_bluetooth: host ${ok ? 'connected' : 'timed out'}');
    return ok;
  }

  /// Dials [address] until it answers or [timeout] runs out.
  Future<bool> join(String address) async {
    if (_connected) return true;
    final deadline = DateTime.now().add(timeout);
    final peer = BluetoothPeer(id: address, name: '', isAppHost: true);
    var attempt = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempt++;
      Logger.diagnostic('room_bluetooth: dial attempt=$attempt');
      final settled = _nextSettled(attemptTimeout);
      unawaited(
        _transport.connectToHost(peer).catchError((Object e) {
          Logger.log('Room Bluetooth dial failed: $e');
        }),
      );
      final state = await settled;
      if (state == BluetoothConnectionState.connected || _connected) {
        Logger.diagnostic('room_bluetooth: joined attempt=$attempt');
        return true;
      }
      // A dial that neither landed nor failed is hung; clear it so the next
      // one starts from a clean socket.
      if (state == null) _transport.reset();
      if (!DateTime.now().add(retryGap).isBefore(deadline)) break;
      await Future<void>.delayed(retryGap);
    }
    Logger.diagnostic('room_bluetooth: join timed out attempts=$attempt');
    return false;
  }

  Future<bool> _nextConnected(Duration within) => _transport.connectionState
      .firstWhere((s) => s == BluetoothConnectionState.connected)
      .then((_) => true)
      .timeout(within, onTimeout: () => _connected);

  /// The next connected or error state, or null if neither came in [within].
  Future<BluetoothConnectionState?> _nextSettled(Duration within) => _transport
      .connectionState
      .cast<BluetoothConnectionState?>()
      .firstWhere(
        (s) =>
            s == BluetoothConnectionState.connected ||
            s == BluetoothConnectionState.error,
      )
      .timeout(within, onTimeout: () => null);
}
