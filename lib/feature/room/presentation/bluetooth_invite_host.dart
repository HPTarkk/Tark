import 'dart:async';

import 'package:get_it/get_it.dart';

import '../../../core/utils/logger.dart';
import '../../transfer/api/transfer_api.dart';
import '../domain/entity/room_invite_link.dart';
import 'room_bluetooth_permissions.dart';

/// The issuer's side of a one-scan invite over Bluetooth.
///
/// Android does not let an app read its own Bluetooth address, so the QR
/// cannot simply name this phone. [start] advertises a fresh rendezvous token
/// and listens; the code carries that token. The scanning phone finds the
/// advertiser, dials it once (which is how this phone learns it has arrived),
/// and both then swap that short finding socket for the real audio link —
/// this phone hosts it, the other dials the address it just reached.
final class BluetoothInviteHost {
  BluetoothInviteHost({
    RoomProximityControlChannel? control,
    BluetoothTransport? transport,
    Future<bool> Function()? permissions,
    this.listenFor = const Duration(minutes: 5),
  }) : _control = control ?? RoomProximityControlChannel(),
       _transport = transport,
       _permissions = permissions ?? ensureRoomInviteBluetoothPermissions;

  final RoomProximityControlChannel _control;
  final BluetoothTransport? _transport;
  final Future<bool> Function() _permissions;

  /// The longest this phone stays findable for one invite.
  final Duration listenFor;

  final BluetoothInviteLink link = BluetoothInviteLink.fresh();

  Future<void>? _peer;
  bool _disposed = false;

  /// Brings the finding side up. Returns the link for the QR, or null when
  /// this phone cannot be found over Bluetooth right now.
  Future<RoomInviteLink?> start() async {
    if (!await _permissions()) {
      Logger.diagnostic('room_invite: bluetooth permission denied');
      return null;
    }
    if (_disposed) return null;
    try {
      await _control.host(rendezvousToken: link.token);
    } on RoomProximityException catch (error) {
      Logger.diagnostic('room_invite: bluetooth host ${error.failure.name}');
      await dispose();
      return null;
    } catch (error) {
      Logger.diagnostic('room_invite: bluetooth host ${error.runtimeType}');
      await dispose();
      return null;
    }
    if (_disposed) return null;
    // Listened for now, not when the code is on screen: the dial-in event is
    // broadcast and would be missed by a listener that came late.
    final peer = _control.waitForPeer(within: listenFor);
    peer.ignore();
    _peer = peer;
    return link;
  }

  /// Waits for the scanning phone to dial in, then hosts the audio link it
  /// will dial next. True once that link is up.
  Future<bool> awaitJoiner({required Duration within}) async {
    final peer = _peer;
    if (peer == null || _disposed) return false;
    try {
      await peer.timeout(within);
    } catch (_) {
      Logger.diagnostic('room_invite: nobody dialed in over bluetooth');
      return false;
    }
    // One Bluetooth socket at a time: the finding socket has to go before the
    // audio link can listen.
    await dispose();
    final transport =
        _transport ??
        (GetIt.instance.isRegistered<BluetoothTransport>()
            ? GetIt.instance<BluetoothTransport>()
            : null);
    if (transport == null) return false;
    return BluetoothLinkHandoff(transport).host();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _control.dispose();
    } catch (_) {
      // Already closed underneath; nothing left to release.
    }
  }
}
