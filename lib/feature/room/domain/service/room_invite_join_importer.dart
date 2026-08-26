import '../entity/room.dart';
import '../repository/room_repository.dart';
import 'room_invite_join_client.dart';
import 'room_invite_join_exchange.dart';

/// Application boundary that turns a correlated issuer acceptance into the
/// joiner's durable local Room state.
///
/// Decoding a QR, receiving an `accepted` response, or knowing a RoomId is not
/// enough to persist membership. [RoomInviteJoinClient] must first verify the
/// exact outstanding request, Room identity, deterministic accepted member and
/// issuer-produced bounded Room snapshot. Only that verified grant reaches the
/// canonical [RoomRepository].
///
/// Transport bootstrap data is deliberately absent from this boundary. Wi-Fi
/// credentials, addresses and temporary host roles never become durable Room
/// identity or membership state. Selection happens only after persistence has
/// succeeded, so a rejected or failed import cannot leave a phantom selection.
/// Unverified responses are therefore a no-op, not a partially-created Room.
final class RoomInviteJoinImporter {
  const RoomInviteJoinImporter({
    required RoomRepository repository,
    RoomInviteJoinClient client = const RoomInviteJoinClient(),
  }) : _repository = repository,
       _client = client;

  final RoomRepository _repository;
  final RoomInviteJoinClient _client;

  /// Verifies, imports and selects the accepted Room.
  ///
  /// Returns null for any unverified/malformed/rejected response and leaves
  /// local persistence untouched. Repository invariant failures are allowed to
  /// surface rather than being converted into a false successful join.
  Future<SavedRoom?> importAcceptedResponse({
    required RoomInviteJoinRequest request,
    required String encodedResponse,
  }) async {
    final grant = _client.verifyAcceptedResponse(
      request: request,
      encodedResponse: encodedResponse,
    );
    if (grant == null) return null;

    final saved = await _repository.importAcceptedJoin(
      grant.snapshot,
      localMemberId: grant.memberId,
    );
    await _repository.select(saved.room.id);
    return saved;
  }
}
