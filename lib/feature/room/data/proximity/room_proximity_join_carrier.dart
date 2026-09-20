import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../../../core/utils/logger.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../../transfer/domain/entity/room_rendezvous_identity.dart';
import '../../domain/entity/room_accepted_join_snapshot.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invite_join_exchange.dart';
import '../../domain/service/room_invite_join_orchestrator.dart';
import '../../domain/service/room_invite_membership_receipt.dart';

final class RoomProximityEnvelope {
  const RoomProximityEnvelope({
    required this.kind,
    required this.roomId,
    required this.requestId,
    required this.joinEpoch,
    required this.payload,
  });

  static const version = 1;

  final String kind;
  final String roomId;
  final String requestId;
  final String joinEpoch;
  final String payload;

  String encode() => jsonEncode({
    'v': version,
    'kind': kind,
    'roomId': roomId,
    'requestId': requestId,
    'joinEpoch': joinEpoch,
    'payload': payload,
  });

  static RoomProximityEnvelope decode(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value['v'] != version) {
      throw const FormatException('proximity envelope version');
    }
    final kind = value['kind'];
    final roomId = value['roomId'];
    final requestId = value['requestId'];
    final joinEpoch = value['joinEpoch'];
    final payload = value['payload'];
    if (kind is! String ||
        roomId is! String ||
        requestId is! String ||
        joinEpoch is! String ||
        payload is! String ||
        !RoomInviteJoinRequest.isValidRequestId(requestId) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(joinEpoch)) {
      throw const FormatException('proximity envelope fields');
    }
    return RoomProximityEnvelope(
      kind: kind,
      roomId: roomId,
      requestId: requestId,
      joinEpoch: joinEpoch,
      payload: payload,
    );
  }
}

final class RoomProximityJoinCarrier
    implements RoomInviteJoinConfirmedSnapshotCarrier {
  RoomProximityJoinCarrier({
    required RoomProximityControlChannel channel,
    required RoomInvitation invitation,
  }) : _channel = channel,
       _invitation = invitation {
    _subscription = _channel.messages.listen(_onMessage);
    _closedSubscription = _channel.closed.listen((_) => _failPending());
  }

  final RoomProximityControlChannel _channel;
  final RoomInvitation _invitation;
  late final StreamSubscription<String> _subscription;
  late final StreamSubscription<void> _closedSubscription;
  final Map<String, Completer<RoomProximityEnvelope>> _pending = {};
  static const _protocolTimeout = Duration(seconds: 10);
  final Random _random = Random.secure();

  @override
  RoomAcceptedJoinSnapshot? confirmedSnapshot;

  String get _epoch => _invitation.invitationId;

  Future<String> get _correlation async =>
      (await RoomRendezvousIdentity.derive(_epoch)).correlation;

  void _onMessage(String raw) {
    RoomProximityEnvelope envelope;
    try {
      envelope = RoomProximityEnvelope.decode(raw);
    } catch (_) {
      return;
    }
    if (envelope.roomId != _invitation.roomId.value ||
        envelope.joinEpoch != _epoch) {
      return;
    }
    final key = '${envelope.kind}:${envelope.requestId}';
    final completer = _pending.remove(key);
    if (completer != null && !completer.isCompleted) {
      completer.complete(envelope);
    }
  }

  void _failPending() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('proximity control channel closed'));
      }
    }
    _pending.clear();
  }

  Future<RoomProximityEnvelope> _sendAndWait({
    required String sendKind,
    required String responseKind,
    required String requestId,
    required String payload,
  }) async {
    final key = '$responseKind:$requestId';
    final existing = _pending[key];
    if (existing != null) return existing.future;
    final completer = Completer<RoomProximityEnvelope>();
    _pending[key] = completer;
    try {
      await _channel.send(
        RoomProximityEnvelope(
          kind: sendKind,
          roomId: _invitation.roomId.value,
          requestId: requestId,
          joinEpoch: _epoch,
          payload: payload,
        ).encode(),
      );
      return await completer.future.timeout(_protocolTimeout);
    } catch (_) {
      final current = _pending[key];
      if (identical(current, completer)) {
        _pending.remove(key);
      }
      rethrow;
    }
  }

  @override
  Future<String> exchange(String encodedRequest) async {
    final request = RoomInviteJoinRequest.decode(encodedRequest);
    if (request.invitation.roomId != _invitation.roomId ||
        request.invitation.invitationId != _invitation.invitationId) {
      throw const FormatException('proximity join request scope');
    }
    final correlation = await _correlation;
    final challenge = Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
    final challengeEncoded = base64Url.encode(challenge).replaceAll('=', '');
    Logger.diagnostic(
      'room_join_protocol: host challenge sent correlation=$correlation',
    );
    final proof = await _sendAndWait(
      sendKind: 'hostChallenge',
      responseKind: 'hostProof',
      requestId: request.requestId,
      payload: challengeEncoded,
    );
    final verified = await _verifyHostProof(
      invitation: _invitation,
      requestId: request.requestId,
      challenge: challenge,
      encodedProof: proof.payload,
    );
    if (!verified) {
      throw StateError('proximity host authentication failed');
    }
    Logger.diagnostic(
      'room_join_protocol: host proof verified correlation=$correlation',
    );
    Logger.diagnostic(
      'room_join_protocol: request sent correlation=$correlation',
    );
    final response = await _sendAndWait(
      sendKind: 'joinRequest',
      responseKind: 'joinGrant',
      requestId: request.requestId,
      payload: encodedRequest,
    );
    Logger.diagnostic(
      'room_join_protocol: grant received correlation=$correlation',
    );
    return response.payload;
  }

  @override
  Future<bool> submitMembershipReceipt(String encodedReceipt) async {
    final receipt = RoomInviteMembershipReceipt.decode(encodedReceipt);
    if (receipt.certificate.roomId != _invitation.roomId) return false;
    final correlation = await _correlation;
    Logger.diagnostic(
      'room_join_protocol: receipt sent correlation=$correlation',
    );
    final response = await _sendAndWait(
      sendKind: 'membershipReceipt',
      responseKind: 'membershipConfirmed',
      requestId: receipt.requestId,
      payload: encodedReceipt,
    );
    try {
      final value = jsonDecode(response.payload);
      if (value is! Map<String, dynamic> || value['ok'] != true) return false;
      final snapshot = value['snapshot'];
      if (snapshot is! String) return false;
      final decoded = RoomAcceptedJoinSnapshot.decode(snapshot);
      if (decoded.roomId != _invitation.roomId) return false;
      final localMemberId = receipt.certificate.memberId;
      final members = decoded.members.where(
        (member) => member.memberId == localMemberId && !member.pending,
      );
      if (members.length != 1) return false;
      confirmedSnapshot = decoded;
      Logger.diagnostic(
        'room_join_protocol: confirmation received correlation=$correlation',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    _failPending();
    await _subscription.cancel();
    await _closedSubscription.cancel();
  }
}

final class RoomProximityJoinIssuerSession {
  RoomProximityJoinIssuerSession({
    required RoomProximityControlChannel channel,
    required RoomInvitation invitation,
    required RoomInviteJoinExchange exchange,
    required RoomRepository repository,
  }) : _channel = channel,
       _invitation = invitation,
       _exchange = exchange,
       _repository = repository {
    _subscription = _channel.messages.listen(_onMessage);
  }

  final RoomProximityControlChannel _channel;
  final RoomInvitation _invitation;
  final RoomInviteJoinExchange _exchange;
  final RoomRepository _repository;
  late final StreamSubscription<String> _subscription;
  final Map<String, String> _grantCache = {};
  final Map<String, Future<String>> _grantInFlight = {};

  Future<String> get _correlation async =>
      (await RoomRendezvousIdentity.derive(
        _invitation.invitationId,
      )).correlation;

  Future<void> _onMessage(String raw) async {
    RoomProximityEnvelope envelope;
    try {
      envelope = RoomProximityEnvelope.decode(raw);
    } catch (_) {
      return;
    }
    if (envelope.roomId != _invitation.roomId.value ||
        envelope.joinEpoch != _invitation.invitationId) {
      return;
    }

    switch (envelope.kind) {
      case 'hostChallenge':
        final correlation = await _correlation;
        final challenge = _decodeChallenge(envelope.payload);
        if (challenge == null) return;
        final proof = await _createHostProof(
          invitation: _invitation,
          requestId: envelope.requestId,
          challenge: challenge,
        );
        await _channel.send(
          RoomProximityEnvelope(
            kind: 'hostProof',
            roomId: envelope.roomId,
            requestId: envelope.requestId,
            joinEpoch: envelope.joinEpoch,
            payload: proof,
          ).encode(),
        );
        Logger.diagnostic(
          'room_join_protocol: host proof sent correlation=$correlation',
        );
        return;
      case 'joinRequest':
        final correlation = await _correlation;
        Logger.diagnostic(
          'room_join_protocol: request received correlation=$correlation',
        );
        final cached = _grantCache[envelope.requestId];
        final Future<String> work;
        if (cached != null) {
          work = Future<String>.value(cached);
        } else {
          work = _grantInFlight.putIfAbsent(
            envelope.requestId,
            () => _exchange.handleEncodedRequest(
              envelope.payload,
              now: DateTime.now().toUtc(),
            ),
          );
        }

        final String response;
        try {
          response = await work;
        } finally {
          if (identical(_grantInFlight[envelope.requestId], work)) {
            _grantInFlight.remove(envelope.requestId);
          }
        }
        _grantCache[envelope.requestId] = response;
        if (_grantCache.length > 16) {
          _grantCache.remove(_grantCache.keys.first);
        }
        await _channel.send(
          RoomProximityEnvelope(
            kind: 'joinGrant',
            roomId: envelope.roomId,
            requestId: envelope.requestId,
            joinEpoch: envelope.joinEpoch,
            payload: response,
          ).encode(),
        );
        Logger.diagnostic(
          'room_join_protocol: grant sent correlation=$correlation',
        );
        return;
      case 'membershipReceipt':
        final correlation = await _correlation;
        Logger.diagnostic(
          'room_join_protocol: receipt received correlation=$correlation',
        );
        final confirmed = await _exchange.handleEncodedReceipt(
          envelope.payload,
        );
        String payload = jsonEncode({'ok': false});
        if (confirmed) {
          try {
            final receipt = RoomInviteMembershipReceipt.decode(
              envelope.payload,
            );
            final saved = await _repository.get(_invitation.roomId);
            if (saved != null) {
              final snapshot = RoomAcceptedJoinSnapshot.fromSavedRoom(
                saved,
                acceptedMemberId: receipt.certificate.memberId,
              );
              payload = jsonEncode({'ok': true, 'snapshot': snapshot.encode()});
            }
          } catch (_) {
            payload = jsonEncode({'ok': false});
          }
        }
        await _channel.send(
          RoomProximityEnvelope(
            kind: 'membershipConfirmed',
            roomId: envelope.roomId,
            requestId: envelope.requestId,
            joinEpoch: envelope.joinEpoch,
            payload: payload,
          ).encode(),
        );
        Logger.diagnostic(
          'room_join_protocol: confirmation sent correlation=$correlation ok=$confirmed',
        );
        return;
      default:
        return;
    }
  }

  Future<void> dispose() => _subscription.cancel();
}


final Hmac _roomHostProofHmac = Hmac.sha256();

Future<String> _createHostProof({
  required RoomInvitation invitation,
  required String requestId,
  required Uint8List challenge,
}) async {
  final mac = await _roomHostProofHmac.calculateMac(
    _hostProofMessage(
      invitation: invitation,
      requestId: requestId,
      challenge: challenge,
    ),
    secretKey: SecretKey(_decodeHex(invitation.secret)),
  );
  return base64Url.encode(mac.bytes).replaceAll('=', '');
}

Future<bool> _verifyHostProof({
  required RoomInvitation invitation,
  required String requestId,
  required Uint8List challenge,
  required String encodedProof,
}) async {
  try {
    final expected = await _createHostProof(
      invitation: invitation,
      requestId: requestId,
      challenge: challenge,
    );
    final expectedBytes = base64Url.decode(base64Url.normalize(expected));
    final actualBytes = base64Url.decode(
      base64Url.normalize(encodedProof.trim()),
    );
    return _constantTimeEquals(expectedBytes, actualBytes);
  } catch (_) {
    return false;
  }
}

Uint8List? _decodeChallenge(String encoded) {
  try {
    final bytes = base64Url.decode(base64Url.normalize(encoded.trim()));
    if (bytes.length != 16) return null;
    return Uint8List.fromList(bytes);
  } catch (_) {
    return null;
  }
}

List<int> _hostProofMessage({
  required RoomInvitation invitation,
  required String requestId,
  required Uint8List challenge,
}) => utf8.encode(
  'tark-room-host-proof-v1\n'
  '${invitation.roomId.value}\n'
  '${invitation.invitationId}\n'
  '$requestId\n'
  '${base64Url.encode(challenge).replaceAll('=', '')}',
);

Uint8List _decodeHex(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('invalid Room invitation secret');
  }
  final output = Uint8List(value.length ~/ 2);
  for (var i = 0; i < output.length; i += 1) {
    output[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return output;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i += 1) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
