import 'dart:convert';

import '../entity/room_invitation.dart';

enum RoomInvitationDecision { accepted, expired, revoked, replayed }

/// Issuer/local-peer revocation and replay ledger for offline Room invites.
///
/// The ledger deliberately stores invitation identifiers, not bearer secrets.
/// Revocation is deterministic on peers that have received the ledger state;
/// it cannot pretend to provide instantaneous global revocation while every
/// device is offline.
final class RoomInvitationLedger {
  RoomInvitationLedger({
    Iterable<String> revoked = const [],
    Iterable<String> redeemed = const [],
  }) : _revoked = {...revoked},
       _redeemed = {...redeemed};

  final Set<String> _revoked;
  final Set<String> _redeemed;

  Set<String> get revokedIds => Set.unmodifiable(_revoked);
  Set<String> get redeemedIds => Set.unmodifiable(_redeemed);

  void revoke(RoomInvitation invite) => _revoked.add(invite.invitationId);

  RoomInvitationDecision evaluate(RoomInvitation invite, DateTime now) {
    if (_revoked.contains(invite.invitationId)) {
      return RoomInvitationDecision.revoked;
    }
    if (invite.singleUse && _redeemed.contains(invite.invitationId)) {
      return RoomInvitationDecision.replayed;
    }
    if (!now.toUtc().isBefore(invite.expiresAt)) {
      return RoomInvitationDecision.expired;
    }
    return RoomInvitationDecision.accepted;
  }

  RoomInvitationDecision redeem(RoomInvitation invite, DateTime now) {
    final decision = evaluate(invite, now);
    if (decision == RoomInvitationDecision.accepted && invite.singleUse) {
      _redeemed.add(invite.invitationId);
    }
    return decision;
  }

  String encodeState() => jsonEncode({
    'v': 1,
    'revoked': _revoked.toList()..sort(),
    'redeemed': _redeemed.toList()..sort(),
  });

  static RoomInvitationLedger decodeState(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value['v'] != 1) {
        throw const FormatException('invite ledger version');
      }
      final revoked = value['revoked'];
      final redeemed = value['redeemed'];
      if (revoked is! List || redeemed is! List) {
        throw const FormatException('invite ledger fields');
      }
      String validate(Object? value) {
        if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
          throw const FormatException('invite ledger id');
        }
        return value;
      }

      return RoomInvitationLedger(
        revoked: revoked.map(validate),
        redeemed: redeemed.map(validate),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed invite ledger');
    }
  }
}
