import 'dart:math';

import '../entity/room_invitation.dart';
import 'room_invite_join_client.dart';
import 'room_invite_join_exchange.dart';
import 'room_member_transport_identity.dart';

/// Minimal transport boundary for one secure Room invite request/response.
abstract interface class RoomInviteJoinCarrier {
  Future<String> exchange(String encodedRequest);
}

enum RoomInviteJoinAttemptStatus {
  accepted,
  rejected,
  roomUnavailable,
  invalidResponse,
  transportFailure,
  cancelled,
}

final class RoomInviteJoinAttemptResult {
  const RoomInviteJoinAttemptResult._({
    required this.status,
    this.grant,
    this.memberKeyPair,
  });

  const RoomInviteJoinAttemptResult.accepted(
    RoomInviteJoinGrant grant, {
    RoomMemberTransportKeyPair? memberKeyPair,
  }) : this._(
         status: RoomInviteJoinAttemptStatus.accepted,
         grant: grant,
         memberKeyPair: memberKeyPair,
       );

  const RoomInviteJoinAttemptResult.rejected()
    : this._(status: RoomInviteJoinAttemptStatus.rejected);

  const RoomInviteJoinAttemptResult.roomUnavailable()
    : this._(status: RoomInviteJoinAttemptStatus.roomUnavailable);

  const RoomInviteJoinAttemptResult.invalidResponse()
    : this._(status: RoomInviteJoinAttemptStatus.invalidResponse);

  const RoomInviteJoinAttemptResult.transportFailure()
    : this._(status: RoomInviteJoinAttemptStatus.transportFailure);

  const RoomInviteJoinAttemptResult.cancelled()
    : this._(status: RoomInviteJoinAttemptStatus.cancelled);

  final RoomInviteJoinAttemptStatus status;
  final RoomInviteJoinGrant? grant;

  /// Ephemeral pending key material. It is never encoded by the carrier and is
  /// handed directly to secure local persistence after the issuer response is
  /// verified.
  final RoomMemberTransportKeyPair? memberKeyPair;
}

/// Joiner-side orchestration for the secure Room join carrier hop.
final class RoomInviteJoinOrchestrator {
  RoomInviteJoinOrchestrator({
    RoomInviteJoinClient client = const RoomInviteJoinClient(),
    RoomMemberTransportIdentityCrypto? identityCrypto,
    Random? random,
  }) : _client = client,
       _identityCrypto = identityCrypto ?? RoomMemberTransportIdentityCrypto(),
       _random = random ?? Random.secure();

  final RoomInviteJoinClient _client;
  final RoomMemberTransportIdentityCrypto _identityCrypto;
  final Random _random;
  int _generation = 0;

  void cancel() {
    _generation += 1;
  }

  Future<RoomInviteJoinAttemptResult> join({
    required RoomInvitation invitation,
    required String displayName,
    required RoomInviteJoinCarrier carrier,
    String? requestId,
  }) async {
    final generation = ++_generation;
    final memberKeyPair = await _identityCrypto.generateKeyPair();
    if (generation != _generation) {
      return const RoomInviteJoinAttemptResult.cancelled();
    }
    final request = RoomInviteJoinRequest(
      requestId: requestId ?? _newRequestId(),
      invitation: invitation,
      displayName: displayName,
      memberTransportPublicKey: memberKeyPair.publicKey,
    );

    final String encodedResponse;
    try {
      encodedResponse = await carrier.exchange(request.encode());
    } catch (_) {
      if (generation != _generation) {
        return const RoomInviteJoinAttemptResult.cancelled();
      }
      return const RoomInviteJoinAttemptResult.transportFailure();
    }
    if (generation != _generation) {
      return const RoomInviteJoinAttemptResult.cancelled();
    }

    final RoomInviteJoinResponse response;
    try {
      response = RoomInviteJoinResponse.decode(encodedResponse);
    } on FormatException {
      return const RoomInviteJoinAttemptResult.invalidResponse();
    }
    if (response.requestId != request.requestId) {
      return const RoomInviteJoinAttemptResult.invalidResponse();
    }

    switch (response.status) {
      case RoomInviteJoinResponseStatus.accepted:
        final grant = _client.verifyAcceptedResponse(
          request: request,
          encodedResponse: encodedResponse,
        );
        if (grant == null || grant.transportCertificate == null) {
          return const RoomInviteJoinAttemptResult.invalidResponse();
        }
        return RoomInviteJoinAttemptResult.accepted(
          grant,
          memberKeyPair: memberKeyPair,
        );
      case RoomInviteJoinResponseStatus.rejected:
        return const RoomInviteJoinAttemptResult.rejected();
      case RoomInviteJoinResponseStatus.roomUnavailable:
        return const RoomInviteJoinAttemptResult.roomUnavailable();
      case RoomInviteJoinResponseStatus.malformed:
        return const RoomInviteJoinAttemptResult.invalidResponse();
    }
  }

  String _newRequestId() {
    final output = StringBuffer();
    for (var index = 0; index < 32; index += 1) {
      output.write(_random.nextInt(16).toRadixString(16));
    }
    return output.toString();
  }
}
