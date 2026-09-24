import 'dart:async';
import 'dart:convert';

import '../../../../core/utils/logger.dart';
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

  bool hasRoom(RoomId roomId) {
    final session = _session;
    return session != null && session.roomId == roomId && session.isOpen;
  }

  /// Whether this phone issued the invite the open session for [roomId] was
  /// built on, or null when there is no open session for it.
  ///
  /// The two ends of one proximity socket are exactly the two phones that
  /// must agree on who raises the first hotspot, and the issuer is the answer
  /// both can reach without an election: it is the phone the other was
  /// standing next to. Deliberately not the Room's creator — a member with
  /// invite rights can bring someone in while the creator is miles away.
  bool? isIssuerFor(RoomId roomId) {
    final session = _session;
    if (session == null || session.roomId != roomId || !session.isOpen) {
      return null;
    }
    return session.issuer;
  }

  Future<void> adopt({
    required RoomId roomId,
    required RoomInvitation invitation,
    required RoomProximityControlChannel channel,
    Future<void> Function()? disposeProtocol,
    HotspotCredentials? Function()? currentHotspotCredentials,
    bool issuer = false,
  }) async {
    final previous = _session;
    final next = _RoomProximityControlSession(
      roomId: roomId,
      invitation: invitation,
      channel: channel,
      disposeProtocol: disposeProtocol,
      currentHotspotCredentials: currentHotspotCredentials,
      issuer: issuer,
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
    if (session == null || session.roomId != roomId || !session.isOpen) {
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
    required Duration timeout,
  }) {
    final session = _session;
    if (session == null || session.roomId != roomId || !session.isOpen) {
      throw StateError('no authenticated proximity session for Room');
    }
    return session.waitForHotspot(
      localTransportEpoch: transportEpoch,
      timeout: timeout,
    );
  }

  /// Tells the other end this phone cannot raise the hand-off's hotspot, so
  /// it should raise one itself. See [RoomHotspotHostDeclined].
  Future<void> declineHotspotHost({required RoomId roomId}) async {
    final session = _session;
    if (session == null || session.roomId != roomId || !session.isOpen) {
      throw StateError('no authenticated proximity session for Room');
    }
    await session.declineHotspotHost();
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
    required this.currentHotspotCredentials,
    required this.issuer,
  }) {
    _messages = channel.messages.listen(_onMessage);
    _closed = channel.closed.listen((_) => _onClosed());
  }

  final RoomId roomId;
  final RoomInvitation invitation;
  final RoomProximityControlChannel channel;
  final Future<void> Function()? disposeProtocol;
  final HotspotCredentials? Function()? currentHotspotCredentials;
  final bool issuer;

  late final StreamSubscription<String> _messages;
  late final StreamSubscription<void> _closed;
  _BufferedHotspot? _bufferedCredential;
  bool _hostDeclined = false;
  Completer<HotspotCredentials>? _credentialWaiter;
  int _lastAcceptedRemoteEpoch = 0;
  int _lastPublishedTransportEpoch = 0;
  bool _peerClosed = false;
  bool _disposed = false;

  bool get isOpen => !_peerClosed && !_disposed;

  static String _epochRequestId(int epoch) {
    if (epoch <= 0) throw ArgumentError.value(epoch, 'epoch');
    final raw = epoch.toRadixString(16);
    if (raw.length > 32) throw ArgumentError.value(epoch, 'epoch');
    return raw.padLeft(32, '0');
  }

  static int? _transportEpochFromRequestId(String requestId) =>
      int.tryParse(requestId, radix: 16);

  Future<void> publishHotspot({
    required int transportEpoch,
    required HotspotCredentials credentials,
  }) {
    if (!isOpen) {
      return Future.error(StateError('proximity control session closed'));
    }
    final requestId = _epochRequestId(transportEpoch);
    if (transportEpoch > _lastPublishedTransportEpoch) {
      _lastPublishedTransportEpoch = transportEpoch;
    }
    Logger.diagnostic(
      'room_transport_control: credentials sent epoch=$transportEpoch',
    );
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

  Future<void> declineHotspotHost() {
    if (!isOpen) {
      return Future.error(StateError('proximity control session closed'));
    }
    Logger.diagnostic('room_transport_control: host declined sent');
    return channel.send(
      RoomProximityEnvelope(
        kind: 'transportHostDeclined',
        roomId: roomId.value,
        requestId: _epochRequestId(1),
        joinEpoch: invitation.invitationId,
        payload: '{}',
      ).encode(),
    );
  }

  Future<HotspotCredentials> waitForHotspot({
    required int localTransportEpoch,
    required Duration timeout,
  }) async {
    if (_hostDeclined) {
      _hostDeclined = false;
      throw const RoomHotspotHostDeclined();
    }
    // Validate the local coordinator epoch, but never require it to equal the
    // host's epoch. Each phone owns its own RoomConnectionCoordinator, so an
    // asymmetric retry can legitimately make those counters differ. The host
    // is authoritative for credential generations on this control session.
    final requestId = _epochRequestId(localTransportEpoch);

    final buffered = _bufferedCredential;
    if (buffered != null && buffered.epoch > _lastAcceptedRemoteEpoch) {
      _bufferedCredential = null;
      _lastAcceptedRemoteEpoch = buffered.epoch;
      return buffered.credentials;
    }
    if (!isOpen) {
      throw StateError('proximity control session closed');
    }

    final existing = _credentialWaiter;
    if (existing != null) return existing.future;

    final waiter = Completer<HotspotCredentials>();
    _credentialWaiter = waiter;
    try {
      Logger.diagnostic(
        'room_transport_control: request sent epoch=$localTransportEpoch',
      );
      await channel.send(
        RoomProximityEnvelope(
          kind: 'transportRequest',
          roomId: roomId.value,
          requestId: requestId,
          joinEpoch: invitation.invitationId,
          payload: '{}',
        ).encode(),
      );
    } catch (error, stackTrace) {
      if (identical(_credentialWaiter, waiter)) {
        _credentialWaiter = null;
      }
      if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
    }
    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      // A retry must send a fresh request. Leaving this completer installed
      // meant every retry inherited a timed-out request and the host never
      // heard that the joiner was still waiting.
      if (identical(_credentialWaiter, waiter)) {
        _credentialWaiter = null;
      }
      Logger.diagnostic(
        'room_transport_control: request timed out epoch=$localTransportEpoch',
      );
      rethrow;
    }
  }

  void _onMessage(String raw) {
    if (!isOpen) return;
    RoomProximityEnvelope envelope;
    try {
      envelope = RoomProximityEnvelope.decode(raw);
    } catch (_) {
      return;
    }
    if (envelope.roomId != roomId.value ||
        envelope.joinEpoch != invitation.invitationId) {
      return;
    }

    if (envelope.kind == 'transportRequest') {
      final requestedEpoch = _transportEpochFromRequestId(envelope.requestId);
      if (requestedEpoch == null || requestedEpoch <= 0) return;
      final credentials = currentHotspotCredentials?.call();
      if (credentials == null) return;

      // This phone already owns a healthy live hotspot. A newly-added member
      // can therefore attach to that same network without asking the existing
      // Room to rebuild its call or press Start again. The response generation
      // is host-owned; the joiner's local coordinator epoch is only a request
      // correlation value and is deliberately not mirrored here.
      final responseEpoch = _lastPublishedTransportEpoch + 1;
      unawaited(
        publishHotspot(
          transportEpoch: responseEpoch,
          credentials: credentials,
        ).catchError((Object _) {}),
      );
      return;
    }

    if (envelope.kind == 'transportHostDeclined') {
      Logger.diagnostic('room_transport_control: host declined received');
      final waiter = _credentialWaiter;
      if (waiter != null && !waiter.isCompleted) {
        _credentialWaiter = null;
        waiter.completeError(const RoomHotspotHostDeclined());
      } else {
        _hostDeclined = true;
      }
      return;
    }

    if (envelope.kind != 'transportCredentials') return;

    final remoteEpoch = _transportEpochFromRequestId(envelope.requestId);
    if (remoteEpoch == null ||
        remoteEpoch <= 0 ||
        remoteEpoch <= _lastAcceptedRemoteEpoch) {
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
      Logger.diagnostic(
        'room_transport_control: credentials received epoch=$remoteEpoch',
      );
      final waiter = _credentialWaiter;
      if (waiter != null && !waiter.isCompleted) {
        _credentialWaiter = null;
        _lastAcceptedRemoteEpoch = remoteEpoch;
        waiter.complete(credentials);
        return;
      }

      final buffered = _bufferedCredential;
      if (buffered == null || remoteEpoch > buffered.epoch) {
        _bufferedCredential = _BufferedHotspot(
          epoch: remoteEpoch,
          credentials: credentials,
        );
      }
    } catch (_) {}
  }

  void _onClosed() {
    if (_peerClosed) return;
    _peerClosed = true;
    Logger.diagnostic('room_transport_control: proximity channel closed');
    final waiter = _credentialWaiter;
    _credentialWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(StateError('proximity control session closed'));
    }
    _bufferedCredential = null;
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

/// The phone expected to raise the hand-off's hotspot cannot (Android 7.x has
/// no LocalOnlyHotspot), so the phone waiting on it should raise one instead.
final class RoomHotspotHostDeclined implements Exception {
  const RoomHotspotHostDeclined();

  @override
  String toString() => 'RoomHotspotHostDeclined';
}

final class _BufferedHotspot {
  const _BufferedHotspot({required this.epoch, required this.credentials});

  final int epoch;
  final HotspotCredentials credentials;
}
