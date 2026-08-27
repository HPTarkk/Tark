import '../entity/room.dart';
import '../repository/room_repository.dart';
import 'room_invite_join_client.dart';
import 'room_invite_join_exchange.dart';
import 'room_member_transport_identity.dart';

typedef PersistJoinedRoomTransportIdentity =
    Future<void> Function({
      required SavedRoom saved,
      required RoomMemberTransportKeyPair memberKeyPair,
      required RoomMemberTransportCertificate certificate,
    });

/// Application boundary that turns a correlated issuer acceptance into the
/// joiner's durable local Room state.
final class RoomInviteJoinImporter {
  const RoomInviteJoinImporter({
    required RoomRepository repository,
    RoomInviteJoinClient client = const RoomInviteJoinClient(),
    PersistJoinedRoomTransportIdentity? persistTransportIdentity,
  }) : _repository = repository,
       _client = client,
       _persistTransportIdentity = persistTransportIdentity;

  final RoomRepository _repository;
  final RoomInviteJoinClient _client;
  final PersistJoinedRoomTransportIdentity? _persistTransportIdentity;

  Future<SavedRoom?> importAcceptedResponse({
    required RoomInviteJoinRequest request,
    required String encodedResponse,
  }) async {
    final grant = _client.verifyAcceptedResponse(
      request: request,
      encodedResponse: encodedResponse,
    );
    if (grant == null) return null;
    return importGrant(grant);
  }

  Future<SavedRoom> importGrant(
    RoomInviteJoinGrant grant, {
    RoomMemberTransportKeyPair? memberKeyPair,
  }) async {
    final existing = await _repository.get(grant.roomId);
    if (existing != null &&
        existing.membership.localMemberId == grant.memberId &&
        existing.room.updatedAt.isAfter(grant.snapshot.roomUpdatedAt)) {
      await _repository.select(existing.room.id);
      return existing;
    }

    final persistIdentity = _persistTransportIdentity;
    final certificate = grant.transportCertificate;
    if (persistIdentity != null &&
        (memberKeyPair == null || certificate == null)) {
      throw const FormatException('secure Room join identity is incomplete');
    }

    final saved = await _repository.importAcceptedJoin(
      grant.snapshot,
      localMemberId: grant.memberId,
    );
    try {
      if (persistIdentity != null) {
        await persistIdentity(
          saved: saved,
          memberKeyPair: memberKeyPair!,
          certificate: certificate!,
        );
      }
    } catch (_) {
      // Never leave a durable membership that production cannot authenticate on
      // the live transport. Roll back this newly imported Room fail closed.
      await _repository.delete(saved.room.id);
      rethrow;
    }
    await _repository.select(saved.room.id);
    return saved;
  }
}
