import 'room_invite_join_exchange.dart';
import 'room_join_peer_binding_authority.dart';

/// Issuer-side carrier boundary for a Room join request whose transport route
/// was observed locally.
///
/// [peerKey] and [attachmentGeneration] are carrier metadata: they are never
/// decoded from the invite/request payload. The route is recorded before
/// verification, but it becomes a durable-member binding only after the
/// canonical [RoomInviteJoinExchange] returns an accepted response for the
/// exact request. The accepted snapshot refreshes the binding registry's
/// membership allow-list before the binding is committed.
final class RoomObservedInviteJoinIssuer {
  const RoomObservedInviteJoinIssuer({
    required this.exchange,
    required this.bindingAuthority,
  });

  final RoomInviteJoinExchange exchange;
  final RoomJoinPeerBindingAuthority bindingAuthority;

  Future<String> handle({
    required String encodedRequest,
    required String peerKey,
    required int attachmentGeneration,
    required DateTime now,
  }) async {
    RoomInviteJoinRequest request;
    try {
      request = RoomInviteJoinRequest.decode(encodedRequest);
    } on FormatException {
      return exchange.handleEncodedRequest(encodedRequest, now: now);
    }

    final observed = bindingAuthority.observeRequest(
      requestId: request.requestId,
      peerKey: peerKey,
      attachmentGeneration: attachmentGeneration,
      at: now,
    );

    final encodedResponse = await exchange.handleEncodedRequest(
      encodedRequest,
      now: now,
    );
    if (!observed) return encodedResponse;

    final response = RoomInviteJoinResponse.decode(encodedResponse);
    if (response.status != RoomInviteJoinResponseStatus.accepted ||
        response.snapshot == null) {
      return encodedResponse;
    }

    bindingAuthority.bindings.replaceMembers(
      response.snapshot!.members.map((member) => member.memberId),
    );
    bindingAuthority.bindAcceptedResponse(
      response: response,
      attachmentGeneration: attachmentGeneration,
      at: now,
    );
    return encodedResponse;
  }
}
