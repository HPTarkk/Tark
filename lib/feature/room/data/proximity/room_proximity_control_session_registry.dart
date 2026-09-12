import 'dart:async';
import 'dart:convert';

import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room.dart';
import '../../domain/entity/room_invitation.dart';
import 'room_proximity_join_carrier.dart';

/// Owns the authenticated proximity socket after membership convergence so
/// transport negotiation never has to fall back to the already-scanned QR.
///
/// The current Android RFCOMM bridge is intentionally one peer at a time. A
/// newer Add-person rendezvous replaces the previous control socket only; the
/// durable Room membership and any already-established Wi-Fi attachment are
/// unaffected.
final class RoomProximityControlSessionRegistry {
  RoomProximityControlSessionRegistry._();

  static final RoomProximityControlSessionRegistry instance =
      RoomProximityControlSessionRegistry._();

  _RoomProximityControlSession? _session;

  bool hasRoom(RoomId roomId) => _session?.roomId == roomId;

  Future<void> adopt({
    required RoomId roomId,
    required RoomInvitation invitation,
    required RoomProximityControlChannel channel,
    Future<void> Function()? disposeProtocol,
  }) async {
    final previous = _session;
    final next = _RoomProximityControlSession(
      roomId: roomId,
      invitation: invitation,
      channel: channel,
      disposeProtocol: disposeProtocol,
    );
    _session = next;
    if (previous != null && previous.channel != channel) {
      await previous.dispose();
    }
  }

  Future<void> publishHotspot({
    required RoomId roomId,
    required int transportEpoch,
    required HotspotCredentials credentials,
  }) async {
    final session = _session;
    if (session == null || session.roomId != roomId) {
      throw StateError('no authenticated proximity session for Room');
    }
    await session.publishHotspot(
      transportEpoch: transportEpoch,
      credentials: credentials,
    );
  }

  Future<HotspotCredentials> waitForHotspot({
    required RoomId roomId,
    required int transportEpoch,
  }) {
    final session = _session;
    if (session == null || session.roomId != roomId) {
      throw StateError('no authenticated proximity session for Room');
    }
    return session.waitForHotspot(transportEpoch: transportEpoch);
  }

  Future<void> clear({RoomId? roomId}) async {
    final session = _session;
    if (session == null || (roomId != null && session.roomId != roomId)) return;
    _session = null;
    await session.dispose();
  }
}

final class _RoomProximityControlSession {
  _RoomProximityControlSession({
    required this.roomId,
    required this.invitation,
    required this.channel,
    required this.disposeProtocol,
  }) {
    _messages = channel.messages.listen(_onMessage);
    _closed = channel.closed.listen((_) => _onClosed());
  }

  final RoomId roomId;
  final RoomInvitation invitation;
  final RoomProximityControlChannel channel;
  final Future<void> Function()? disposeProtocol;

  late final StreamSubscription<String> _messages;
  late final StreamSubscription<void> _closed;
  final Map<String, HotspotCredentials> _bufferedCredentials = {};
  final Map<String, Completer<HotspotCredentials>> _credentialWaiters = {};
  bool _disposed = false;

  static String _epochRequestId(int epoch) {
    if (epoch < 0) throw ArgumentError.value(epoch, 'epoch');
    final raw = epoch.toRadixString(16);
    if (raw.length > 32) throw ArgumentError.value(epoch, 'epoch');
    return raw.padLeft(32, '0');
  }

  Future<void> publishHotspot({
    required int transportEpoch,
    required HotspotCredentials credentials,
  }) {
    final requestId = _epochRequestId(transportEpoch);
    return channel.send(
      RoomProximityEnvelope(
        kind: 'transportCredentials',
        roomId: roomId.value,
        requestId: requestId,
        joinEpoch: invitation.invitationId,
        payload: jsonEncode({
          'ssid': credentials.ssid,
          'passphrase': credentials.passphrase,
          'security': credentials.security,
        }),
      ).encode(),
    );
  }

  Future<HotspotCredentials> waitForHotspot({required int transportEpoch}) {
    final requestId = _epochRequestId(transportEpoch);
    final buffered = _bufferedCredentials.remove(requestId);
    if (buffered != null) return Future.value(buffered);
    if (_disposed) {
      return Future.error(StateError('proximity control session closed'));
    }
    return (_credentialWaiters[requestId] ??=
            Completer<HotspotCredentials>())
        .future;
  }

  void _onMessage(String raw) {
    RoomProximityEnvelope envelope;
    try {
      envelope = RoomProximityEnvelope.decode(raw);
    } catch (_) {
      return;
    }
    if (envelope.kind != 'transportCredentials' ||
        envelope.roomId != roomId.value ||
        envelope.joinEpoch != invitation.invitationId) {
      return;
    }

    try {
      final value = jsonDecode(envelope.payload);
      if (value is! Map<String, dynamic>) return;
      final ssid = value['ssid'];
      final passphrase = value['passphrase'];
      final security = value['security'];
      if (ssid is! String ||
          ssid.isEmpty ||
          passphrase is! String ||
          security is! String ||
          security.isEmpty) {
        return;
      }
      final credentials = HotspotCredentials(
        ssid: ssid,
        passphrase: passphrase,
        security: security,
      );
      final waiter = _credentialWaiters.remove(envelope.requestId);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(credentials);
      } else {
        // Host can become ready a few milliseconds before the peer enters its
        // execute-plan branch. Buffer one exact transport epoch, never a blind
        // retry or timer.
        _bufferedCredentials[envelope.requestId] = credentials;
        if (_bufferedCredentials.length > 4) {
          _bufferedCredentials.remove(_bufferedCredentials.keys.first);
        }
      }
    } catch (_) {
      // Untrusted control payload: fail closed and keep waiting for a valid
      // message on the same authenticated/correlated socket.
    }
  }

  void _onClosed() {
    for (final waiter in _credentialWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('proximity control session closed'));
      }
    }
    _credentialWaiters.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onClosed();
    await _messages.cancel();
    await _closed.cancel();
    await disposeProtocol?.call();
    await channel.dispose();
  }
}
