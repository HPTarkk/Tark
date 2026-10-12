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

/// One link of an invite delegation chain: the certificate of a member who
/// was allowed to invite, exactly as its own issuer signed it.
///
/// The issuer of link `i` is the Room root key for `i == 0` and the member key
/// of link `i - 1` otherwise. [inviteGrant] is required on every link — a
/// member without the right to invite can never appear as somebody else's
/// issuer, which is the whole of the no-escalation rule.
final class RoomInviteDelegation {
  const RoomInviteDelegation({
    required this.memberId,
    required this.memberPublicKey,
    required this.issuerSignature,
    required this.inviteGrant,
  });

  final RoomMemberId memberId;
  final List<int> memberPublicKey;
  final List<int> issuerSignature;
  final List<int> inviteGrant;
}

/// Issuer-signed durable binding between one [RoomMemberId] and its public key.
///
/// The certificate contains no route, IP, device id or transport role. Those are
/// live attachment facts and are proven separately by a challenge signature
/// after the transport has matched an actual Pong token/source route.
///
/// ## Invite rights
///
/// Whether the holder may invite other people is carried *inside* signed data
/// rather than beside it: [inviteGrant] is the issuer's signature over a
/// dedicated `tark-room-invite-grant-v1` message naming this Room, member,
/// member key and issuer key. A flag nobody signed means nothing, and a grant
/// that does not verify fails the whole certificate rather than quietly
/// downgrading, so a tampered QR cannot be imported at all.
///
/// A member holding a grant issues certificates with its *own member key*, and
/// proves it was allowed to by carrying its own certificate as an
/// [issuerChain] link. Every receiver walks the chain back to the one Room root
/// key it already trusts; a link without a valid grant breaks the walk. Nobody
/// can therefore hand out a right they were not themselves given.
///
/// ## Wire format
///
/// * Root-issued certificates stay version 1 JSON, byte-identical to earlier
///   builds when no grant is present. A grant rides as one optional `grant`
///   key, which every older decoder ignores — so a granted member is still a
///   perfectly ordinary member to a phone that predates this.
/// * Delegated certificates are version 2, a compact binary record (see
///   [_encodeDelegated]). Older builds reject that version cleanly: they could
///   not verify a member key they never heard of anyway.
final class RoomMemberTransportCertificate {
  const RoomMemberTransportCertificate({
    required this.roomId,
    required this.memberId,
    required this.memberPublicKey,
    required this.issuerPublicKey,
    required this.issuerSignature,
    this.inviteGrant,
    this.issuerChain = const [],
    List<int>? chainRootPublicKey,
  }) : _chainRootPublicKey = chainRootPublicKey;

  static const currentVersion = 1;

  /// The binary layout used only when [issuerChain] is non-empty.
  static const delegatedVersion = 2;

  /// Longest [issuerChain] any certificate may carry.
  ///
  /// Two links is creator → A → B → C: three generations of invites below the
  /// person who made the Room, for a Room that holds at most twelve people. The
  /// bound exists for the wire, not for policy: a route proof has to fit one
  /// 2 KiB control record with an 80-character name riding beside it.
  static const maxIssuerChain = 2;

  static const maxEncodedLength = 1024;

  final RoomId roomId;
  final RoomMemberId memberId;
  final List<int> memberPublicKey;

  /// Whoever signed this certificate: the Room root key, or for a delegated
  /// certificate the member key of the last [issuerChain] link.
  final List<int> issuerPublicKey;
  final List<int> issuerSignature;

  /// The issuer's signature granting this member the right to invite, or null.
  final List<int>? inviteGrant;

  /// Certificates of the members who passed the invite right down to this
  /// one's issuer, root-most first. Empty for a root-issued certificate.
  final List<RoomInviteDelegation> issuerChain;

  final List<int>? _chainRootPublicKey;

  /// The Room trust anchor every member compares against.
  ///
  /// Use this — never [issuerPublicKey] — wherever the question is "is this
  /// the same Room key I trust": for a delegated certificate the two differ.
  List<int> get rootIssuerPublicKey => issuerChain.isEmpty
      ? issuerPublicKey
      : (_chainRootPublicKey ?? const <int>[]);

  /// Structurally granted. Only
  /// [RoomMemberTransportIdentityCrypto.verifyCertificate] says whether the
  /// grant is genuine.
  bool get canInvite => inviteGrant != null;

  /// Whether this holder may issue a certificate at all.
  bool get canIssue => canInvite && issuerChain.length < maxIssuerChain;

  /// Whether a certificate this holder issues may itself carry a grant.
  bool get canGrantOnward =>
      canInvite && issuerChain.length + 1 < maxIssuerChain;

  /// This certificate as the next link of a chain it is about to sign under.
  RoomInviteDelegation asDelegation() {
    final grant = inviteGrant;
    if (grant == null) {
      throw StateError('certificate carries no invite grant');
    }
    return RoomInviteDelegation(
      memberId: memberId,
      memberPublicKey: memberPublicKey,
      issuerSignature: issuerSignature,
      inviteGrant: grant,
    );
  }

  String encode() {
    final String encoded;
    if (issuerChain.isEmpty) {
      final grant = inviteGrant;
      final raw = jsonEncode({
        'v': currentVersion,
        'roomId': roomId.value,
        'memberId': memberId.value,
        'memberKey': _encodeBytes(memberPublicKey),
        'issuerKey': _encodeBytes(issuerPublicKey),
        'signature': _encodeBytes(issuerSignature),
        // Optional and last, so an ungranted certificate encodes to exactly
        // the bytes it always did.
        if (grant != null) 'grant': _encodeBytes(grant),
      });
      encoded = _encodeBytes(utf8.encode(raw));
    } else {
      encoded = _encodeBytes(_encodeDelegated(this));
    }
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
      final bytes = _decode(encoded);
      // Version 1 is JSON and therefore always opens with `{`; the binary
      // layout opens with its version byte.
      if (bytes.isNotEmpty && bytes.first == delegatedVersion) {
        return _decodeDelegated(bytes);
      }
      final value = jsonDecode(utf8.decode(bytes));
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
      final grantRaw = value['grant'];
      if (grantRaw != null && grantRaw is! String) {
        throw const FormatException('Room member invite grant');
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
        // A present but malformed grant is refused outright, never read as
        // "no grant": that would let a corrupted field pass as a valid,
        // merely less-privileged certificate.
        inviteGrant: grantRaw is String
            ? List.unmodifiable(_decodeSized(grantRaw, 64, 'invite grant'))
            : null,
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

const _delegatedFlagGrant = 0x01;

/// Version 2: a delegated certificate.
///
/// | bytes | field |
/// | ---: | :--- |
/// | 1 | version (`2`) |
/// | 16 | room id |
/// | 12 | member id |
/// | 32 | member public key |
/// | 32 | Room root public key |
/// | 64 | signature by the last link's member key |
/// | 1 | flags — bit 0: an invite grant follows; others must be zero |
/// | 64 | invite grant (only with bit 0) |
/// | 1 | link count, 1…[RoomMemberTransportCertificate.maxIssuerChain] |
/// | 172 each | link: member id 12, member key 32, signature 64, grant 64 |
///
/// The leaf's issuer key is not written: it is by definition the last link's
/// member key, and a second copy could only ever agree or contradict.
List<int> _encodeDelegated(RoomMemberTransportCertificate certificate) {
  final chain = certificate.issuerChain;
  if (chain.isEmpty ||
      chain.length > RoomMemberTransportCertificate.maxIssuerChain) {
    throw const FormatException('Room member certificate chain length');
  }
  if (!_sameBytes(certificate.issuerPublicKey, chain.last.memberPublicKey)) {
    throw const FormatException('Room member certificate issuer mismatch');
  }
  final out = <int>[RoomMemberTransportCertificate.delegatedVersion];
  void fixed(List<int> value, int length) {
    if (value.length != length) {
      throw const FormatException('Room member certificate field width');
    }
    out.addAll(value);
  }

  void hex(String value, int length) {
    if (value.length != length * 2) {
      throw const FormatException('Room member certificate identifier');
    }
    for (var i = 0; i < value.length; i += 2) {
      final byte = int.tryParse(value.substring(i, i + 2), radix: 16);
      if (byte == null) {
        throw const FormatException('Room member certificate identifier');
      }
      out.add(byte);
    }
  }

  hex(certificate.roomId.value, 16);
  hex(certificate.memberId.value, 12);
  fixed(certificate.memberPublicKey, 32);
  fixed(certificate.rootIssuerPublicKey, 32);
  fixed(certificate.issuerSignature, 64);
  final grant = certificate.inviteGrant;
  out.add(grant == null ? 0 : _delegatedFlagGrant);
  if (grant != null) fixed(grant, 64);
  out.add(chain.length);
  for (final link in chain) {
    hex(link.memberId.value, 12);
    fixed(link.memberPublicKey, 32);
    fixed(link.issuerSignature, 64);
    fixed(link.inviteGrant, 64);
  }
  return out;
}

RoomMemberTransportCertificate _decodeDelegated(List<int> bytes) {
  var offset = 1;
  List<int> take(int length) {
    if (bytes.length - offset < length) {
      throw const FormatException('Room member certificate truncated');
    }
    final slice = List<int>.unmodifiable(
      bytes.sublist(offset, offset + length),
    );
    offset += length;
    return slice;
  }

  String hex(int length) =>
      take(length).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  final roomId = RoomId(hex(16));
  final memberId = RoomMemberId(hex(12));
  final memberKey = take(32);
  final root = take(32);
  final signature = take(64);
  final flags = take(1).single;
  if (flags & ~_delegatedFlagGrant != 0) {
    throw const FormatException('Room member certificate flags');
  }
  final grant = flags & _delegatedFlagGrant != 0 ? take(64) : null;
  final count = take(1).single;
  if (count < 1 || count > RoomMemberTransportCertificate.maxIssuerChain) {
    throw const FormatException('Room member certificate chain length');
  }
  final chain = <RoomInviteDelegation>[
    for (var i = 0; i < count; i++)
      RoomInviteDelegation(
        memberId: RoomMemberId(hex(12)),
        memberPublicKey: take(32),
        issuerSignature: take(64),
        inviteGrant: take(64),
      ),
  ];
  if (offset != bytes.length) {
    throw const FormatException('Room member certificate trailing bytes');
  }
  return RoomMemberTransportCertificate(
    roomId: roomId,
    memberId: memberId,
    memberPublicKey: memberKey,
    issuerPublicKey: chain.last.memberPublicKey,
    issuerSignature: signature,
    inviteGrant: grant,
    issuerChain: List.unmodifiable(chain),
    chainRootPublicKey: root,
  );
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

  /// Signs a member certificate.
  ///
  /// With no [issuerCertificate], [issuer] is the Room root key. With one,
  /// [issuer] is that certificate's *member* key pair and the result is a
  /// delegated certificate whose chain proves the issuer held the invite
  /// right. [grantInvite] passes the right on; it is refused when the issuer
  /// could not itself pass it on, so the capability can only ever narrow on
  /// the way down.
  Future<RoomMemberTransportCertificate> issueCertificate({
    required RoomId roomId,
    required RoomMemberId memberId,
    required List<int> memberPublicKey,
    required RoomMemberTransportKeyPair issuer,
    bool grantInvite = false,
    RoomMemberTransportCertificate? issuerCertificate,
  }) async {
    _requireSized(memberPublicKey, 32, 'member public key');
    var chain = const <RoomInviteDelegation>[];
    List<int>? root;
    if (issuerCertificate != null) {
      if (issuerCertificate.roomId != roomId) {
        throw ArgumentError('issuer certificate belongs to another Room');
      }
      if (!_sameBytes(issuer.publicKey, issuerCertificate.memberPublicKey)) {
        throw ArgumentError('issuer key does not match issuer certificate');
      }
      if (!issuerCertificate.canIssue) {
        throw StateError('issuer certificate carries no usable invite right');
      }
      if (grantInvite && !issuerCertificate.canGrantOnward) {
        throw StateError('issuer cannot pass the invite right on');
      }
      chain = List.unmodifiable([
        ...issuerCertificate.issuerChain,
        issuerCertificate.asDelegation(),
      ]);
      root = issuerCertificate.rootIssuerPublicKey;
    }
    final keyPair = _keyPair(issuer);
    final signature = await _algorithm.sign(
      _certificateMessage(roomId, memberId, memberPublicKey),
      keyPair: keyPair,
    );
    final grant = grantInvite
        ? await _algorithm.sign(
            _inviteGrantMessage(
              roomId,
              memberId,
              memberPublicKey,
              issuer.publicKey,
            ),
            keyPair: keyPair,
          )
        : null;
    return RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: List.unmodifiable(memberPublicKey),
      issuerPublicKey: List.unmodifiable(issuer.publicKey),
      issuerSignature: List.unmodifiable(signature.bytes),
      inviteGrant: grant == null ? null : List.unmodifiable(grant.bytes),
      issuerChain: chain,
      chainRootPublicKey: root,
    );
  }

  /// Whether [certificate] descends from [expectedIssuerPublicKey], the Room
  /// root key, through nothing but members who were allowed to invite.
  ///
  /// Fails closed on every path: a wrong root, a chain longer than the format
  /// allows, a link without a valid grant, a leaf signed by anyone but the last
  /// link, a grant deeper than may be granted — and a grant on the leaf that
  /// does not verify, so tampering with the capability fails the whole
  /// certificate rather than silently reading as "no grant".
  Future<bool> verifyCertificate({
    required RoomMemberTransportCertificate certificate,
    required List<int> expectedIssuerPublicKey,
  }) async {
    final chain = certificate.issuerChain;
    if (chain.length > RoomMemberTransportCertificate.maxIssuerChain) {
      return false;
    }
    if (!_sameBytes(certificate.rootIssuerPublicKey, expectedIssuerPublicKey)) {
      return false;
    }
    if (certificate.inviteGrant != null &&
        chain.length >= RoomMemberTransportCertificate.maxIssuerChain) {
      return false;
    }
    final seen = <String>{certificate.memberId.value};
    try {
      var signer = expectedIssuerPublicKey;
      for (final link in chain) {
        if (!seen.add(link.memberId.value)) return false;
        if (!await _verify(
          _certificateMessage(
            certificate.roomId,
            link.memberId,
            link.memberPublicKey,
          ),
          link.issuerSignature,
          signer,
        )) {
          return false;
        }
        if (!await _verify(
          _inviteGrantMessage(
            certificate.roomId,
            link.memberId,
            link.memberPublicKey,
            signer,
          ),
          link.inviteGrant,
          signer,
        )) {
          return false;
        }
        signer = link.memberPublicKey;
      }
      if (!_sameBytes(certificate.issuerPublicKey, signer)) return false;
      if (!await _verify(
        _certificateMessage(
          certificate.roomId,
          certificate.memberId,
          certificate.memberPublicKey,
        ),
        certificate.issuerSignature,
        signer,
      )) {
        return false;
      }
      final grant = certificate.inviteGrant;
      if (grant != null &&
          !await _verify(
            _inviteGrantMessage(
              certificate.roomId,
              certificate.memberId,
              certificate.memberPublicKey,
              signer,
            ),
            grant,
            signer,
          )) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _verify(
    List<int> message,
    List<int> signature,
    List<int> publicKey,
  ) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    return _algorithm.verify(
      message,
      signature: Signature(signature, publicKey: _publicKey(publicKey)),
    );
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

  /// Its own domain, so a certificate signature can never be presented as a
  /// grant or the other way round. The issuer key is inside the message: a
  /// grant lifted onto a certificate from a different issuer cannot verify.
  List<int> _inviteGrantMessage(
    RoomId roomId,
    RoomMemberId memberId,
    List<int> memberPublicKey,
    List<int> issuerPublicKey,
  ) => utf8.encode(
    'tark-room-invite-grant-v1\n'
    '${roomId.value}\n${memberId.value}\n${_encodeBytes(memberPublicKey)}\n'
    '${_encodeBytes(issuerPublicKey)}',
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
