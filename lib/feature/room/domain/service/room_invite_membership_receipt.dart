import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../entity/room.dart';
import 'room_invite_join_exchange.dart';
import 'room_member_transport_identity.dart';

/// Joiner-signed acknowledgement for a specific accepted invite exchange.
///
/// The issuer creates an invite seat before the other phone has actually
/// received the response. This receipt proves that the holder of the certified
/// member key received that exact response. It is deliberately carrier-neutral
/// so Bluetooth control, LAN control and a future QR recovery carrier can use
/// the same durable-membership rule.
final class RoomInviteMembershipReceipt {
  const RoomInviteMembershipReceipt({
    required this.requestId,
    required this.certificate,
    required this.signature,
  });

  static const _version = 1;
  static const maxEncodedLength = 3072;

  final String requestId;
  final RoomMemberTransportCertificate certificate;
  final List<int> signature;

  String encode() {
    if (!RoomInviteJoinRequest.isValidRequestId(requestId) ||
        signature.length != 64) {
      throw const FormatException('invalid Room membership receipt');
    }
    final encoded = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'v': _version,
              'requestId': requestId,
              'certificate': certificate.encode(),
              'signature': _encode(signature),
            }),
          ),
        )
        .replaceAll('=', '');
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('Room membership receipt too large');
    }
    return encoded;
  }

  static RoomInviteMembershipReceipt decode(String encoded) {
    final raw = encoded.trim();
    if (raw.isEmpty || raw.length > maxEncodedLength) {
      throw const FormatException('Room membership receipt size');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      );
      if (value is! Map<String, dynamic> || value['v'] != _version) {
        throw const FormatException('Room membership receipt version');
      }
      final requestId = value['requestId'];
      final certificate = value['certificate'];
      final signature = value['signature'];
      if (requestId is! String ||
          !RoomInviteJoinRequest.isValidRequestId(requestId) ||
          certificate is! String ||
          signature is! String) {
        throw const FormatException('Room membership receipt fields');
      }
      return RoomInviteMembershipReceipt(
        requestId: requestId,
        certificate: RoomMemberTransportCertificate.decode(certificate),
        signature: List.unmodifiable(_decodeSized(signature, 64)),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed Room membership receipt');
    }
  }
}

/// Cryptographic receipt minting and verification. The signed transcript
/// includes the issuer certificate, so a receipt cannot move between Rooms,
/// members, requests or issuers.
abstract final class RoomInviteMembershipReceiptCrypto {
  static final Ed25519 _algorithm = Ed25519();

  static Future<RoomInviteMembershipReceipt> sign({
    required String requestId,
    required RoomMemberTransportCertificate certificate,
    required RoomMemberTransportKeyPair member,
  }) async {
    if (!RoomInviteJoinRequest.isValidRequestId(requestId) ||
        !_sameBytes(member.publicKey, certificate.memberPublicKey)) {
      throw ArgumentError('invalid Room membership receipt signer');
    }
    final signature = await _algorithm.sign(
      _message(requestId, certificate),
      keyPair: SimpleKeyPairData(
        member.privateKey,
        publicKey: SimplePublicKey(member.publicKey, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      ),
    );
    return RoomInviteMembershipReceipt(
      requestId: requestId,
      certificate: certificate,
      signature: List.unmodifiable(signature.bytes),
    );
  }

  static Future<bool> verify({
    required RoomInviteMembershipReceipt receipt,
    required RoomId expectedRoomId,
    required RoomMemberId expectedMemberId,
    required List<int> expectedIssuerPublicKey,
  }) async {
    final certificate = receipt.certificate;
    if (certificate.roomId != expectedRoomId ||
        certificate.memberId != expectedMemberId ||
        !_sameBytes(certificate.issuerPublicKey, expectedIssuerPublicKey)) {
      return false;
    }
    try {
      final certificateValid = await _algorithm.verify(
        _certificateMessage(certificate),
        signature: Signature(
          certificate.issuerSignature,
          publicKey: SimplePublicKey(
            certificate.issuerPublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!certificateValid) return false;
      return await _algorithm.verify(
        _message(receipt.requestId, certificate),
        signature: Signature(
          receipt.signature,
          publicKey: SimplePublicKey(
            certificate.memberPublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  static List<int> _message(
    String requestId,
    RoomMemberTransportCertificate certificate,
  ) => utf8.encode(
    'tark-room-membership-receipt-v1\\n'
    '$requestId\\n${certificate.roomId.value}\\n${certificate.memberId.value}\\n'
    '${_encode(certificate.memberPublicKey)}\\n'
    '${_encode(certificate.issuerPublicKey)}',
  );

  static List<int> _certificateMessage(
    RoomMemberTransportCertificate certificate,
  ) => utf8.encode(
    'tark-room-member-certificate-v1\\n'
    '${certificate.roomId.value}\\n${certificate.memberId.value}\\n'
    '${_encode(certificate.memberPublicKey)}',
  );
}

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _decodeSized(String encoded, int expectedLength) {
  try {
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    if (bytes.length != expectedLength) {
      throw const FormatException('Room membership receipt signature size');
    }
    return bytes;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Room membership receipt signature encoding');
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var index = 0; index < a.length; index += 1) {
    difference |= a[index] ^ b[index];
  }
  return difference == 0;
}
