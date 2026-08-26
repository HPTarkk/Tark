import 'dart:math';

import '../entity/room_invitation.dart';
import 'room_invite_join_client.dart';
import 'room_invite_join_exchange.dart';

/// Minimal transport boundary for one secure Room invite request/response.
///
/// Implementations may use an existing local peer channel, QR-assisted local
/// handoff, or another already-supported carrier. The carrier is deliberately
/// ignorant of Room membership semantics: it only moves bounded encoded data.
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
  const RoomInviteJoinAttemptResult._({required this.status, this.grant});

  const RoomInviteJoinAttemptResult.accepted(RoomInviteJoinGrant grant)
    : this._(status: RoomInviteJoinAttemptStatus.accepted, grant: grant);

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
}

/// Joiner-side orchestration for the first real carrier hop of secure Room join.
///
/// Parsing a QR/link never authorizes membership. This service turns that bearer
/// capability into a correlated request, sends it through an injected carrier,
/// rejects cross-attempt/cross-request replies, and delegates accepted-response
/// verification to [RoomInviteJoinClient]. Only the returned verified grant may
/// proceed to [RoomInviteJoinImporter] for durable local persistence.
///
/// At most one attempt generation is current. Starting another attempt or
/// calling [cancel] makes any delayed response from the previous carrier a
/// harmless cancelled result, preventing an old join from mutating later UI or
/// persistence state.
final class RoomInviteJoinOrchestrator {
  RoomInviteJoinOrchestrator({
    RoomInviteJoinClient client = const RoomInviteJoinClient(),
    Random? random,
  }) : _client = client,
       _random = random ?? Random.secure();

  final RoomInviteJoinClient _client;
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
    final request = RoomInviteJoinRequest(
      requestId: requestId ?? _newRequestId(),
      invitation: invitation,
      displayName: displayName,
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
        return grant == null
            ? const RoomInviteJoinAttemptResult.invalidResponse()
            : RoomInviteJoinAttemptResult.accepted(grant);
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
