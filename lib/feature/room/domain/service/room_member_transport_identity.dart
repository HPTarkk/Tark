import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../entity/room.dart';

/// Ed25519 key material used only for proving a durable Room member on a live
/// transport route. Private bytes never belong in Room snapshots, QR output or
/// diagnostics.
final class RoomMemberTransportKeyPair {
  const RoomMemberTransportKeyPair({
    required this.privateKey,
    required this.publicKey,
  });

  final List<int> privateKey;
  final List<int> publicKey;

  String get encodedPrivateKey => _encodeBytes(privateKey);
  String get encodedPublicKey => _encodeBytes(publicKey);

  static RoomMemberTransportKeyPair decode({
    required String privateKey,
    required String publicKey,
  }) {
    final privateBytes = _decodeSized(privateKey, 32, 'private key');
    final publicBytes = _decodeSized(publicKey, 32, 'public key');
    return RoomMemberTransportKeyPair(
      privateKey: List.unmodifiable(privateBytes),
      publicKey: List.unmodifiable(publicBytes),
    );
  }
}

/// Issuer-signed durable binding between one [RoomMemberId] and its public key.
///
/// The certificate contains no route, IP, device id or transport role. Those are
/// live attachment facts and are proven separately by a challenge signature
/// after the transport has matched an actual Pong token/source route.
final class RoomMemberTransportCertificate {
  const RoomMemberTransportCertificate({
    required this.roomId,
    required this.memberId,
    required this.memberPublicKey,
    required this.issuerPublicKey,
    required this.issuerSignature,
  });

  static const currentVersion = 1;
  static const maxEncodedLength = 1024;

  final RoomId roomId;
  final RoomMemberId memberId;
  final List<int> memberPublicKey;
  final List<int> issuerPublicKey;
  final List<int> issuerSignature;

  String encode() {
    final raw = jsonEncode({
      'v': currentVersion,
      'roomId': roomId.value,
      'memberId': memberId.value,
      'memberKey': _encodeBytes(memberPublicKey),
      'issuerKey': _encodeBytes(issuerPublicKey),
      'signature': _encodeBytes(issuerSignature),
    });
    final encoded = _encodeBytes(utf8.encode(raw));
    if (encoded.length > maxEncodedLength) {
      throw const FormatException(
        'Room member transport certificate too large',
      );
    }
    return encoded;
  }

  static RoomMemberTransportCertificate decode(String encoded) {
    if (encoded.trim().isEmpty || encoded.length > maxEncodedLength) {
      throw const FormatException('Room member transport certificate size');
    }
    try {
      final value = jsonDecode(utf8.decode(_decode(encoded)));
      if (value is! Map<String, dynamic> || value['v'] != currentVersion) {
        throw const FormatException(
          'Room member transport certificate version',
        );
      }
      final roomId = RoomId.parse(value['roomId'] as String? ?? '');
      final memberIdRaw = value['memberId'];
      if (roomId == null ||
          memberIdRaw is! String ||
          !RegExp(r'^[0-9a-f]{24}$').hasMatch(memberIdRaw)) {
        throw const FormatException(
          'Room member transport certificate identity',
        );
      }
      return RoomMemberTransportCertificate(
        roomId: roomId,
        memberId: RoomMemberId(memberIdRaw),
        memberPublicKey: List.unmodifiable(
          _decodeSized(value['memberKey'] as String? ?? '', 32, 'member key'),
        ),
        issuerPublicKey: List.unmodifiable(
          _decodeSized(value['issuerKey'] as String? ?? '', 32, 'issuer key'),
        ),
        issuerSignature: List.unmodifiable(
          _decodeSized(
            value['signature'] as String? ?? '',
            64,
            'issuer signature',
          ),
        ),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
        'Malformed Room member transport certificate',
      );
    }
  }
}

/// One matched-heartbeat proof. The signature is deliberately challenge-bound:
/// replaying a certificate alone, or replaying an old proof on a later ping,
/// cannot establish current transport identity.
final class RoomMemberTransportProof {
  const RoomMemberTransportProof({
    required this.certificate,
    required this.token,
    required this.sessionEpoch,
    required this.memberSignature,
  });

  static const currentVersion = 1;
  static const maxEncodedLength = 2048;

  final RoomMemberTransportCertificate certificate;
  final int token;
  final int sessionEpoch;
  final List<int> memberSignature;

  String encode() {
    _requireUint32(token, 'token');
    _requireUint32(sessionEpoch, 'sessionEpoch');
    final raw = jsonEncode({
      'v': currentVersion,
      'certificate': certificate.encode(),
      'token': token,
      'epoch': sessionEpoch,
      'signature': _encodeBytes(memberSignature),
    });
    final encoded = _encodeBytes(utf8.encode(raw));
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('Room member transport proof too large');
    }
    return encoded;
  }

  static RoomMemberTransportProof decode(String encoded) {
    if (encoded.trim().isEmpty || encoded.length > maxEncodedLength) {
      throw const FormatException('Room member transport proof size');
    }
    try {
      final value = jsonDecode(utf8.decode(_decode(encoded)));
      if (value is! Map<String, dynamic> || value['v'] != currentVersion) {
        throw const FormatException('Room member transport proof version');
      }
      final token = value['token'];
      final epoch = value['epoch'];
      if (token is! int || epoch is! int) {
        throw const FormatException('Room member transport proof challenge');
      }
      _requireUint32(token, 'token');
      _requireUint32(epoch, 'sessionEpoch');
      return RoomMemberTransportProof(
        certificate: RoomMemberTransportCertificate.decode(
          value['certificate'] as String? ?? '',
        ),
        token: token,
        sessionEpoch: epoch,
        memberSignature: List.unmodifiable(
          _decodeSized(
            value['signature'] as String? ?? '',
            64,
            'member signature',
          ),
        ),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed Room member transport proof');
    }
  }
}

/// Cryptographic operations for Room transport identity.
///
/// All signed messages use explicit domain separation and canonical ASCII/UTF-8
/// fields. This prevents a signature created for a member certificate from ever
/// being interpreted as a heartbeat proof (or vice versa).
final class RoomMemberTransportIdentityCrypto {
  RoomMemberTransportIdentityCrypto({Ed25519? algorithm})
    : _algorithm = algorithm ?? Ed25519();

  final Ed25519 _algorithm;

  Future<RoomMemberTransportKeyPair> generateKeyPair() async {
    final keyPair = await _algorithm.newKeyPair();
    final extracted = await keyPair.extract();
    return RoomMemberTransportKeyPair(
      privateKey: List.unmodifiable(extracted.bytes),
      publicKey: List.unmodifiable(extracted.publicKey.bytes),
    );
  }

  Future<RoomMemberTransportCertificate> issueCertificate({
    required RoomId roomId,
    required RoomMemberId memberId,
    required List<int> memberPublicKey,
    required RoomMemberTransportKeyPair issuer,
  }) async {
    _requireSized(memberPublicKey, 32, 'member public key');
    final signature = await _algorithm.sign(
      _certificateMessage(roomId, memberId, memberPublicKey),
      keyPair: _keyPair(issuer),
    );
    return RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: List.unmodifiable(memberPublicKey),
      issuerPublicKey: List.unmodifiable(issuer.publicKey),
      issuerSignature: List.unmodifiable(signature.bytes),
    );
  }

  Future<bool> verifyCertificate({
    required RoomMemberTransportCertificate certificate,
    required List<int> expectedIssuerPublicKey,
  }) async {
    if (!_sameBytes(certificate.issuerPublicKey, expectedIssuerPublicKey)) {
      return false;
    }
    try {
      return await _algorithm.verify(
        _certificateMessage(
          certificate.roomId,
          certificate.memberId,
          certificate.memberPublicKey,
        ),
        signature: Signature(
          certificate.issuerSignature,
          publicKey: _publicKey(certificate.issuerPublicKey),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<RoomMemberTransportProof> signProof({
    required RoomMemberTransportCertificate certificate,
    required RoomMemberTransportKeyPair member,
    required int token,
    required int sessionEpoch,
  }) async {
    _requireUint32(token, 'token');
    _requireUint32(sessionEpoch, 'sessionEpoch');
    if (!_sameBytes(member.publicKey, certificate.memberPublicKey)) {
      throw ArgumentError('member key does not match certificate');
    }
    final signature = await _algorithm.sign(
      _proofMessage(certificate, token, sessionEpoch),
      keyPair: _keyPair(member),
    );
    return RoomMemberTransportProof(
      certificate: certificate,
      token: token,
      sessionEpoch: sessionEpoch,
      memberSignature: List.unmodifiable(signature.bytes),
    );
  }

  Future<bool> verifyProof({
    required RoomMemberTransportProof proof,
    required RoomId expectedRoomId,
    required List<int> expectedIssuerPublicKey,
    required int expectedToken,
    required int expectedSessionEpoch,
  }) async {
    if (proof.certificate.roomId != expectedRoomId ||
        proof.token != expectedToken ||
        proof.sessionEpoch != expectedSessionEpoch) {
      return false;
    }
    if (!await verifyCertificate(
      certificate: proof.certificate,
      expectedIssuerPublicKey: expectedIssuerPublicKey,
    )) {
      return false;
    }
    try {
      return await _algorithm.verify(
        _proofMessage(proof.certificate, proof.token, proof.sessionEpoch),
        signature: Signature(
          proof.memberSignature,
          publicKey: _publicKey(proof.certificate.memberPublicKey),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  SimpleKeyPairData _keyPair(RoomMemberTransportKeyPair key) =>
      SimpleKeyPairData(
        key.privateKey,
        publicKey: _publicKey(key.publicKey),
        type: KeyPairType.ed25519,
      );

  SimplePublicKey _publicKey(List<int> bytes) =>
      SimplePublicKey(bytes, type: KeyPairType.ed25519);

  List<int> _certificateMessage(
    RoomId roomId,
    RoomMemberId memberId,
    List<int> memberPublicKey,
  ) => utf8.encode(
    'tark-room-member-certificate-v1\n'
    '${roomId.value}\n${memberId.value}\n${_encodeBytes(memberPublicKey)}',
  );

  List<int> _proofMessage(
    RoomMemberTransportCertificate certificate,
    int token,
    int sessionEpoch,
  ) => utf8.encode(
    'tark-room-member-proof-v1\n'
    '${certificate.roomId.value}\n${certificate.memberId.value}\n'
    '$token\n$sessionEpoch',
  );
}

String _encodeBytes(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _decode(String value) {
  try {
    return base64Url.decode(base64Url.normalize(value.trim()));
  } catch (_) {
    throw const FormatException('invalid base64url');
  }
}

List<int> _decodeSized(String value, int length, String label) {
  final bytes = _decode(value);
  _requireSized(bytes, length, label);
  return bytes;
}

void _requireSized(List<int> bytes, int length, String label) {
  if (bytes.length != length) {
    throw FormatException('$label must be $length bytes');
  }
}

void _requireUint32(int value, String label) {
  if (value < 0 || value > 0xffffffff) {
    throw FormatException('$label must be uint32');
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
