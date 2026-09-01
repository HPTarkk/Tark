import 'dart:convert';

import 'room.dart';
import 'room_accepted_join_snapshot.dart';
import '../service/room_member_transport_identity.dart';

/// A pre-authorised, single-scan Room handoff.
///
/// The inviter creates a fresh member identity and signs it before displaying
/// the QR. Scanning therefore gives the new phone everything it needs to save
/// the logical Room and authenticate on the later Wi-Fi/hotspot transport;
/// there is no second phone-to-phone QR dance.
final class RoomDirectJoinBundle {
  const RoomDirectJoinBundle({
    required this.memberId,
    required this.snapshot,
    required this.memberKeyPair,
    required this.certificate,
    required this.expiresAt,
  });

  static const currentVersion = 1;
  static const maxEncodedLength = 12288;

  final RoomMemberId memberId;
  final RoomAcceptedJoinSnapshot snapshot;
  final RoomMemberTransportKeyPair memberKeyPair;
  final RoomMemberTransportCertificate certificate;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  String encode() {
    if (certificate.roomId != snapshot.roomId ||
        certificate.memberId != memberId ||
        !_sameBytes(certificate.memberPublicKey, memberKeyPair.publicKey)) {
      throw const FormatException('direct Room join identity mismatch');
    }
    final localMember = snapshot.members.where(
      (member) => member.memberId == memberId,
    );
    if (localMember.length != 1) {
      throw const FormatException('direct Room join member missing');
    }
    final json = jsonEncode({
      'v': currentVersion,
      'memberId': memberId.value,
      'snapshot': snapshot.encode(),
      'privateKey': memberKeyPair.encodedPrivateKey,
      'publicKey': memberKeyPair.encodedPublicKey,
      'certificate': certificate.encode(),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
    });
    final encoded = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('direct Room join QR too large');
    }
    return 'tark-room:$encoded';
  }

  static RoomDirectJoinBundle decode(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('tark-room:')) {
      throw const FormatException('not a direct Room invite');
    }
    final encoded = trimmed.substring('tark-room:'.length);
    if (encoded.isEmpty || encoded.length > maxEncodedLength) {
      throw const FormatException('direct Room join QR size');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
      if (value is! Map<String, dynamic> || value['v'] != currentVersion) {
        throw const FormatException('direct Room join version');
      }
      final memberIdRaw = value['memberId'];
      final expiresRaw = value['expiresAt'];
      if (memberIdRaw is! String ||
          !RegExp(r'^[0-9a-f]{24}$').hasMatch(memberIdRaw) ||
          expiresRaw is! String) {
        throw const FormatException('direct Room join fields');
      }
      final bundle = RoomDirectJoinBundle(
        memberId: RoomMemberId(memberIdRaw),
        snapshot: RoomAcceptedJoinSnapshot.decode(value['snapshot'] as String),
        memberKeyPair: RoomMemberTransportKeyPair.decode(
          privateKey: value['privateKey'] as String,
          publicKey: value['publicKey'] as String,
        ),
        certificate: RoomMemberTransportCertificate.decode(
          value['certificate'] as String,
        ),
        expiresAt: DateTime.parse(expiresRaw).toUtc(),
      );
      // Re-run all cross-field checks in one canonical place.
      bundle.encode();
      if (bundle.isExpired) throw const FormatException('Room invite expired');
      return bundle;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed direct Room invite');
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index += 1) {
    diff |= a[index] ^ b[index];
  }
  return diff == 0;
}
