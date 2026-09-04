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

/// A member's own name for itself, signed with the key its certificate binds.
///
/// Not challenge-bound, and deliberately so: a name does not change between
/// heartbeats, so it is signed once when a session opens and rides every proof
/// after that. Replaying it proves only what it claims — that the holder of
/// this certified member key calls itself this — which is the entire claim.
///
/// It is a *self*-claim, and that is the right strength for it. The host has no
/// independent source for a joiner's name; one-scan entry opens the seat before
/// anyone can say who will take it. What the signature buys is that nobody
/// *else* on the network can name you, and that an unverified string never
/// enters the roster.
final class RoomMemberSignedName {
  const RoomMemberSignedName({required this.name, required this.signature});

  /// Matches [RoomAcceptedJoinSnapshot.maxDisplayNameLength]: the same name
  /// travels both ways, and a bound one side will not honour is not a bound.
  static const maxLength = 80;

  final String name;
  final List<int> signature;

  static bool isWellFormed(String name) {
    final clean = name.trim();
    return clean.isNotEmpty && clean.length <= maxLength;
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
    this.name,
  });

  static const currentVersion = 1;
  static const maxEncodedLength = 2048;

  final RoomMemberTransportCertificate certificate;
  final int token;
  final int sessionEpoch;
  final List<int> memberSignature;

  /// Display metadata riding beside the proof, or null when the peer sent
  /// none — which every build older than R27b does.
  ///
  /// Carried in its own separately-signed field rather than folded into
  /// [_proofMessage], so a build that predates this and one that does not
  /// still verify each other's proofs. The route binding is the load-bearing
  /// thing here; a name must never be able to cost one.
  final RoomMemberSignedName? name;

  String encode() {
    _requireUint32(token, 'token');
    _requireUint32(sessionEpoch, 'sessionEpoch');
    final signedName = name;
    final raw = jsonEncode({
      'v': currentVersion,
      'certificate': certificate.encode(),
      'token': token,
      'epoch': sessionEpoch,
      'signature': _encodeBytes(memberSignature),
      // Written only as a pair and only when there is a name to write, so a
      // proof from a phone that has not named itself is byte-identical to one
      // minted before this field existed.
      if (signedName != null) ...{
        'name': signedName.name,
        'nameSig': _encodeBytes(signedName.signature),
      },
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
        name: _decodeName(value),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed Room member transport proof');
    }
  }

  /// The optional name pair, or null for anything that is not exactly one.
  ///
  /// Absent, half-present, oversized or unparseable all answer the same way:
  /// no name. Rejecting the whole proof over a bad optional field would let a
  /// corrupted name break route binding, which is the one thing here that
  /// matters — the name is settled afterwards, by verifying this signature
  /// against the certificate the proof carries.
  static RoomMemberSignedName? _decodeName(Map<String, dynamic> value) {
    final name = value['name'];
    final signature = value['nameSig'];
    if (name is! String ||
        signature is! String ||
        !RoomMemberSignedName.isWellFormed(name)) {
      return null;
    }
    try {
      return RoomMemberSignedName(
        name: name.trim(),
        signature: List.unmodifiable(
          _decodeSized(signature, 64, 'member name signature'),
        ),
      );
    } on FormatException {
      return null;
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
    RoomMemberSignedName? name,
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
      name: name,
    );
  }

  /// Signs what this phone calls itself in one Room.
  ///
  /// Minted once per session and attached to every proof after that: the name
  /// is not challenge-bound, because unlike presence it does not need to be
  /// fresh to be true. Room and member are inside the message, so a name
  /// signed for one Room cannot be replayed into another.
  Future<RoomMemberSignedName?> signMemberName({
    required RoomMemberTransportCertificate certificate,
    required RoomMemberTransportKeyPair member,
    required String name,
  }) async {
    final clean = name.trim();
    if (!RoomMemberSignedName.isWellFormed(clean)) return null;
    if (!_sameBytes(member.publicKey, certificate.memberPublicKey)) {
      throw ArgumentError('member key does not match certificate');
    }
    final signature = await _algorithm.sign(
      _memberNameMessage(certificate, clean),
      keyPair: _keyPair(member),
    );
    return RoomMemberSignedName(
      name: clean,
      signature: List.unmodifiable(signature.bytes),
    );
  }

  /// Whether a name really came from the member whose certificate carries it.
  ///
  /// [expectedRoomId] is checked here as well as in [verifyProof] so this can
  /// never be called as a bare name check on a certificate from elsewhere.
  Future<bool> verifyMemberName({
    required RoomMemberTransportCertificate certificate,
    required RoomMemberSignedName name,
    required RoomId expectedRoomId,
  }) async {
    if (certificate.roomId != expectedRoomId) return false;
    if (!RoomMemberSignedName.isWellFormed(name.name)) return false;
    try {
      return await _algorithm.verify(
        _memberNameMessage(certificate, name.name.trim()),
        signature: Signature(
          name.signature,
          publicKey: _publicKey(certificate.memberPublicKey),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// Signs an instruction to move the Room onto a new carrier.
  ///
  /// Takes the fields rather than the assembled announcement so that the
  /// message this covers is defined exactly once, here, alongside the other
  /// two — which is what keeps a signature made for one purpose from ever
  /// verifying as another.
  Future<List<int>> signCarrierHandover({
    required RoomMemberTransportCertificate certificate,
    required RoomMemberTransportKeyPair member,
    required int generation,
    required String ssid,
    required String passphrase,
    required DateTime issuedAt,
  }) async {
    _requireUint32(generation, 'generation');
    if (!_sameBytes(member.publicKey, certificate.memberPublicKey)) {
      throw ArgumentError('member key does not match certificate');
    }
    final signature = await _algorithm.sign(
      _carrierHandoverMessage(
        certificate,
        generation,
        ssid,
        passphrase,
        issuedAt,
      ),
      keyPair: _keyPair(member),
    );
    return List.unmodifiable(signature.bytes);
  }

  /// Whether an announced carrier really came from a member of this Room.
  ///
  /// Fails closed on every path. The attack this exists to stop is somebody
  /// within earshot of the current network telling the group to move onto an
  /// access point they control, and a "probably fine" here would hand them the
  /// whole Room.
  Future<bool> verifyCarrierHandover({
    required RoomMemberTransportCertificate certificate,
    required List<int> signature,
    required RoomId expectedRoomId,
    required List<int> expectedIssuerPublicKey,
    required int generation,
    required String ssid,
    required String passphrase,
    required DateTime issuedAt,
  }) async {
    if (certificate.roomId != expectedRoomId) return false;
    if (!await verifyCertificate(
      certificate: certificate,
      expectedIssuerPublicKey: expectedIssuerPublicKey,
    )) {
      return false;
    }
    try {
      return await _algorithm.verify(
        _carrierHandoverMessage(
          certificate,
          generation,
          ssid,
          passphrase,
          issuedAt,
        ),
        signature: Signature(
          signature,
          publicKey: _publicKey(certificate.memberPublicKey),
        ),
      );
    } catch (_) {
      return false;
    }
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

  /// Every field a receiver acts on, in a fixed order with unambiguous
  /// separators. Signing a subset would let an attacker keep a genuine
  /// signature and swap what was left out — the SSID being the obvious one.
  List<int> _carrierHandoverMessage(
    RoomMemberTransportCertificate certificate,
    int generation,
    String ssid,
    String passphrase,
    DateTime issuedAt,
  ) => utf8.encode(
    'tark-room-carrier-handover-v1\n'
    '${certificate.roomId.value}\n${certificate.memberId.value}\n'
    '$generation\n$ssid\n$passphrase\n'
    '${issuedAt.toUtc().toIso8601String()}',
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

  /// Its own domain, deliberately not a longer proof message.
  ///
  /// Adding the name to [_proofMessage] would have been a stronger binding and
  /// the wrong trade: a build that signed the old message and one that
  /// verifies the new one would stop recognising each other, on the single
  /// path where two phones in a room have to agree. A separate domain costs
  /// one signature and breaks nothing — and the two can never be confused for
  /// one another, which is what the prefixes are for.
  List<int> _memberNameMessage(
    RoomMemberTransportCertificate certificate,
    String name,
  ) => utf8.encode(
    'tark-room-member-name-v1\n'
    '${certificate.roomId.value}\n${certificate.memberId.value}\n'
    '$name',
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
