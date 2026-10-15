import 'dart:convert';
import 'dart:typed_data';

import 'room.dart';
import 'room_accepted_join_snapshot.dart';
import '../service/room_member_transport_identity.dart';

/// A pre-authorised, single-scan Room handoff.
///
/// The inviter creates a fresh member identity and signs it before displaying
/// the QR. Scanning therefore gives the new phone everything it needs to save
/// the logical Room and authenticate on the later Wi-Fi/hotspot transport;
/// there is no second phone-to-phone QR dance.
///
/// ## Wire format
///
/// `tark-room:` followed by unpadded base64url. Versions 2, 3 and 4 pack a
/// compact binary record; version 1 packed a JSON envelope. All four are
/// still read so a code minted by an older build keeps working. Only v3 (an
/// invite that grants nothing) and v4 (one that carries a signed invite right
/// or delegation chain) are ever written.
///
/// ### Why v1 was replaced
///
/// A two-member v1 bundle encoded to ~1600 characters, which put the QR at
/// roughly 137 modules a side. Rendered at 250 logical pixels that is under two
/// pixels per module before device scaling — right at the edge of what a phone
/// camera can resolve off another phone's screen, and why this code used to be
/// harder to scan than the hotspot one.
///
/// Almost all of it was self-inflicted. `snapshot` and `certificate` were each
/// base64url strings that then got base64url'd again as part of the envelope,
/// so their bytes paid the 4/3 expansion twice; the ids were carried as hex
/// (two characters per byte); every timestamp was a 24-character ISO string;
/// and the certificate repeated the room and member ids the envelope already
/// held. v2 removes all four, and the same bundle now encodes to ~400
/// characters — small enough to fit at error-correction level Q, which is what
/// lets the invite carry the centre brand mark.
///
/// ### The v2 layout
///
/// Fields are written in this order, with no separators or field names:
///
/// | bytes | field |
/// | ---: | :--- |
/// | 1 | version (`2`) |
/// | 1 | flags — bit 0 grants invite management, rest reserved zero |
/// | 16 | room id |
/// | 12 | accepted member id |
/// | 32 | member private key |
/// | 32 | member public key |
/// | 32 | issuer public key |
/// | 64 | issuer signature over the certificate |
/// | varint | invite expiry, ms since epoch |
/// | varint | room created at, ms since epoch |
/// | varint | room updated at, ms since epoch |
/// | varint + n | room name, UTF-8 |
/// | varint | member count |
/// | … | per member: 12-byte id, kind byte, joined-at varint, name |
///
/// ### What v3 adds
///
/// v2 dropped two facts the roster needs, and dropping them is R27's bug
/// arriving on the path R27 was actually about. A held invite seat travels in
/// the snapshot as an ordinary active member — the JSON codec learned to say
/// `pending`, but this binary one never did, so a one-scan joiner still
/// received the host's unclaimed seats as people. And a seat's hold (R27c) has
/// to travel too: the joining phone has no back-channel, so a seat that
/// expires on the host and not here is the same divergence one phone over.
///
/// Both ride in the byte that already carried the member kind, whose low bits
/// only ever used two values:
///
/// | bits | meaning |
/// | ---: | :--- |
/// | 0–3 | kind — 0 member, 1 guest |
/// | 4 | the seat is held open and nobody has walked through it |
/// | 5 | a held-until varint follows the joined-at one |
///
/// So a roster with no held seats encodes to exactly the byte count v2 did,
/// and the code keeps the module size it had. A record with held seats pays a
/// varint each, which is what a seat that can expire costs.
///
/// The flags could not simply be added to v2: an older reader would take bit 4
/// as an unknown kind and, worse, the extra varint would desynchronise every
/// field after it. A version byte is exactly what this format has for that.
///
/// ### What v4 adds
///
/// The right to invite other people, *signed* (ITEM 10). v2/v3 carried it as
/// flag bit 0 and nothing else, which any byte editor could flip; and a joiner
/// it was granted to still could not invite, because the right was never
/// backed by a key. v4 carries the certificate's invite grant signature and,
/// for a member invited by another member rather than by the Room's creator,
/// the delegation chain that proves the inviter was allowed to:
///
/// | bytes | field |
/// | ---: | :--- |
/// | 1 | version (`4`) |
/// | 1 | flags — bit 0 an invite grant follows, bit 1 a chain follows |
/// | 16, 12, 32, 32 | room id, member id, member private key, public key |
/// | 32 | the Room *root* key (the leaf issuer when there is no chain) |
/// | 64 | issuer signature over the certificate |
/// | 64 | invite grant signature (bit 0 only) |
/// | 1 + 172 each | chain links (bit 1 only), see the certificate's own v2 |
/// | … | then exactly v3, from the expiry onwards |
///
/// Bit 0 is not trusted on its own: it says a grant *follows*, and whether
/// that grant is genuine is decided by verifying it against the Room key
/// before anything is saved. Unknown flag bits are refused, unlike v3.
///
/// v4 is written only when there is a grant or a chain to carry. An invite
/// that grants nothing still goes out as v3, byte for byte, so every older
/// build can keep scanning it.
///
/// The certificate's own room and member ids are not written: [encode] already
/// refuses a bundle whose certificate disagrees with the envelope, so a second
/// copy could only ever be redundant or a contradiction. Same for the
/// certificate's member public key, which must equal the key pair's.
final class RoomDirectJoinBundle {
  const RoomDirectJoinBundle({
    required this.memberId,
    required this.snapshot,
    required this.memberKeyPair,
    required this.certificate,
    required this.expiresAt,
  });

  /// The layout this build writes for an invite that grants nothing — the
  /// same one the previous build wrote, so it can still scan it.
  static const currentVersion = 3;

  /// The layout this build writes when the certificate carries a signed
  /// invite grant or a delegation chain.
  static const delegatedVersion = 4;

  /// The first binary layout. Read, never written: it cannot say that a seat
  /// is held, so a code minted by that build arrives with the host's open
  /// seats looking like members. Nothing can recover that here — the bytes do
  /// not carry it — and the alternative to reading them is refusing a scan.
  static const binaryVersionWithoutSeats = 2;

  /// The JSON envelope earlier builds wrote. Read, never written.
  static const legacyVersion = 1;

  static const maxEncodedLength = 12288;

  static const _scheme = 'tark-room:';

  final RoomMemberId memberId;
  final RoomAcceptedJoinSnapshot snapshot;
  final RoomMemberTransportKeyPair memberKeyPair;
  final RoomMemberTransportCertificate certificate;
  final DateTime expiresAt;

  /// The [FormatException] message [decode] throws for a code whose time is
  /// up, so a reader can tell "ask for a new code" apart from "not a code".
  static const expiredMessage = 'Room invite expired';

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  String encode() {
    _assertConsistent();
    final encoded = base64Url.encode(_writeBinary(this)).replaceAll('=', '');
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('direct Room join QR too large');
    }
    return '$_scheme$encoded';
  }

  /// Whether [raw] is even *claiming* to be a Room invite.
  ///
  /// Every failure inside [decode] is one `FormatException`, which is right
  /// for a decoder and wrong for a message: "that invite is invalid or
  /// expired" is accurate for a code that really is one of ours and a lie for
  /// a payload that never was. This is the cheap half of telling those apart,
  /// and it is the same check [decode] opens with.
  static bool looksLikeInvite(String raw) => raw.trim().startsWith(_scheme);

  static RoomDirectJoinBundle decode(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith(_scheme)) {
      throw const FormatException('not a direct Room invite');
    }
    final encoded = trimmed.substring(_scheme.length);
    if (encoded.isEmpty || encoded.length > maxEncodedLength) {
      throw const FormatException('direct Room join QR size');
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(encoded));
      // v1 is JSON, so its first byte is always `{`. No binary layout can be
      // confused for it, or for another, by that leading byte.
      final bundle = switch (bytes.isEmpty ? -1 : bytes.first) {
        delegatedVersion => _readBinary(
          Uint8List.fromList(bytes),
          seats: true,
          delegated: true,
        ),
        currentVersion => _readBinary(Uint8List.fromList(bytes), seats: true),
        binaryVersionWithoutSeats => _readBinary(
          Uint8List.fromList(bytes),
          seats: false,
        ),
        _ => _readV1(bytes),
      };
      // Re-run all cross-field checks in one canonical place, whichever
      // layout the bytes arrived in.
      bundle._assertConsistent();
      if (bundle.isExpired) throw const FormatException(expiredMessage);
      return bundle;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed direct Room invite');
    }
  }

  /// The certificate, the key pair and the roster have to describe one member
  /// of one Room, or the scanning phone would save an identity it cannot
  /// authenticate with.
  void _assertConsistent() {
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
  }
}

const _flagGrantsInviteManagement = 0x01;

/// v4 only: a delegation chain follows the grant.
const _flagDelegationChain = 0x02;

/// The member byte: kind in the low nibble, seat facts above it.
const _memberKindMask = 0x0F;
const _memberFlagPending = 0x10;
const _memberFlagHeldUntil = 0x20;
const _memberByteMask =
    _memberKindMask | _memberFlagPending | _memberFlagHeldUntil;
const _roomIdBytes = 16;
const _memberIdBytes = 12;
const _keyBytes = 32;
const _signatureBytes = 64;

/// Seven groups of seven bits. The ceiling that buys — year 19,800 in
/// milliseconds — is far past any real timestamp, and stays under the 2^53
/// where web integers stop being exact: `int` is a double there, so a wider
/// varint would silently lose its tail rather than fail.
const _maxVarintBytes = 7;
const _maxVarintValue = 0x1FFFFFFFFFFFF;

/// Longest UTF-8 run any single string field may claim. Both the room name
/// (120 characters) and a display name (80) stay well inside this even when
/// every character costs four bytes.
const _maxTextBytes = 512;

/// Writes v3, or v4 when the certificate has a grant or a chain to carry.
Uint8List _writeBinary(RoomDirectJoinBundle bundle) {
  final snapshot = bundle.snapshot;
  final certificate = bundle.certificate;
  final grant = certificate.inviteGrant;
  final chain = certificate.issuerChain;
  final delegated = grant != null || chain.isNotEmpty;
  final out = _ByteWriter();
  if (delegated) {
    // The unsigned roster flag must say what the signed certificate says. A
    // bundle that disagrees with itself is refused rather than written.
    if (snapshot.grantsInviteManagement != (grant != null)) {
      throw const FormatException('direct Room join grant mismatch');
    }
    out
      ..u8(RoomDirectJoinBundle.delegatedVersion)
      ..u8(
        (grant != null ? _flagGrantsInviteManagement : 0) |
            (chain.isNotEmpty ? _flagDelegationChain : 0),
      );
  } else {
    out
      ..u8(RoomDirectJoinBundle.currentVersion)
      ..u8(snapshot.grantsInviteManagement ? _flagGrantsInviteManagement : 0);
  }
  out
    ..hex(snapshot.roomId.value, _roomIdBytes)
    ..hex(bundle.memberId.value, _memberIdBytes)
    ..fixed(bundle.memberKeyPair.privateKey, _keyBytes)
    ..fixed(bundle.memberKeyPair.publicKey, _keyBytes)
    ..fixed(certificate.rootIssuerPublicKey, _keyBytes)
    ..fixed(certificate.issuerSignature, _signatureBytes);
  if (grant != null) out.fixed(grant, _signatureBytes);
  if (chain.isNotEmpty) {
    if (chain.length > RoomMemberTransportCertificate.maxIssuerChain) {
      throw const FormatException('direct Room join chain length');
    }
    out.u8(chain.length);
    for (final link in chain) {
      out
        ..hex(link.memberId.value, _memberIdBytes)
        ..fixed(link.memberPublicKey, _keyBytes)
        ..fixed(link.issuerSignature, _signatureBytes)
        ..fixed(link.inviteGrant, _signatureBytes);
    }
  }
  out
    ..timestamp(bundle.expiresAt)
    ..timestamp(snapshot.roomCreatedAt)
    ..timestamp(snapshot.roomUpdatedAt)
    ..text(snapshot.roomName)
    ..varint(snapshot.members.length);
  for (final member in snapshot.members) {
    // A hold means nothing on a seat nobody is holding, so it is written only
    // under the mark — which also keeps the two flags from ever disagreeing.
    final held = member.pending ? member.heldUntil : null;
    out
      ..hex(member.memberId.value, _memberIdBytes)
      ..u8(
        _wireKind(member.kind) |
            (member.pending ? _memberFlagPending : 0) |
            (held != null ? _memberFlagHeldUntil : 0),
      )
      ..timestamp(member.joinedAt);
    if (held != null) out.timestamp(held);
    out.text(member.displayName);
  }
  return out.take();
}

/// Reads every binary layout.
///
/// [seats] says whether the member flags exist, which is the only thing v3
/// added; [delegated] says whether the v4 certificate extension does. Sharing
/// the reader rather than copying it keeps them from drifting: everything
/// else is byte-identical, and a bug fixed in one would otherwise have to be
/// remembered in the others.
RoomDirectJoinBundle _readBinary(
  Uint8List bytes, {
  required bool seats,
  bool delegated = false,
}) {
  final input = _ByteReader(bytes);
  input.u8(); // Version, already matched by the caller.
  final flags = input.u8();
  if (delegated &&
      flags & ~(_flagGrantsInviteManagement | _flagDelegationChain) != 0) {
    throw const FormatException('direct Room join flags');
  }
  final roomId = RoomId(input.hex(_roomIdBytes));
  final memberId = RoomMemberId(input.hex(_memberIdBytes));
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: input.fixed(_keyBytes),
    publicKey: input.fixed(_keyBytes),
  );
  final rootKey = input.fixed(_keyBytes);
  final signature = input.fixed(_signatureBytes);
  final grant = delegated && flags & _flagGrantsInviteManagement != 0
      ? input.fixed(_signatureBytes)
      : null;
  final chain = <RoomInviteDelegation>[];
  if (delegated && flags & _flagDelegationChain != 0) {
    final links = input.u8();
    if (links < 1 || links > RoomMemberTransportCertificate.maxIssuerChain) {
      throw const FormatException('direct Room join chain length');
    }
    for (var index = 0; index < links; index += 1) {
      chain.add(
        RoomInviteDelegation(
          memberId: RoomMemberId(input.hex(_memberIdBytes)),
          memberPublicKey: input.fixed(_keyBytes),
          issuerSignature: input.fixed(_signatureBytes),
          inviteGrant: input.fixed(_signatureBytes),
        ),
      );
    }
  }
  if (delegated && grant == null && chain.isEmpty) {
    // v4 exists only to carry one of the two. A record claiming neither is not
    // something this build writes.
    throw const FormatException('direct Room join empty delegation');
  }
  final certificate = RoomMemberTransportCertificate(
    roomId: roomId,
    memberId: memberId,
    memberPublicKey: keyPair.publicKey,
    issuerPublicKey: chain.isEmpty ? rootKey : chain.last.memberPublicKey,
    issuerSignature: signature,
    inviteGrant: grant,
    issuerChain: List.unmodifiable(chain),
    chainRootPublicKey: chain.isEmpty ? null : rootKey,
  );
  final expiresAt = input.timestamp();
  final roomCreatedAt = input.timestamp();
  final roomUpdatedAt = input.timestamp();
  final roomName = input.text();
  final count = input.varint();
  if (count < 1 || count > RoomAcceptedJoinSnapshot.maxMembers) {
    throw const FormatException('direct Room join roster size');
  }
  final members = <RoomAcceptedJoinMember>[
    for (var index = 0; index < count; index += 1) _readMember(input, seats),
  ];
  // Nothing may follow the roster. A record that decodes cleanly and then
  // leaves bytes on the table is not this format.
  input.assertExhausted();
  return RoomDirectJoinBundle(
    memberId: memberId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: roomName,
      roomCreatedAt: roomCreatedAt,
      roomUpdatedAt: roomUpdatedAt,
      members: members,
      // v2/v3 carried this unsigned; it is read for what it says and
      // decided by nothing. The importer takes the right from the
      // certificate alone. In v4 it is the grant's presence, which the
      // certificate check then verifies.
      grantsInviteManagement: flags & _flagGrantsInviteManagement != 0,
    ),
    memberKeyPair: keyPair,
    certificate: certificate,
    expiresAt: expiresAt,
  );
}

RoomDirectJoinBundle _readV1(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, dynamic> ||
      value['v'] != RoomDirectJoinBundle.legacyVersion) {
    throw const FormatException('direct Room join version');
  }
  final memberIdRaw = value['memberId'];
  final expiresRaw = value['expiresAt'];
  if (memberIdRaw is! String ||
      !RegExp(r'^[0-9a-f]{24}$').hasMatch(memberIdRaw) ||
      expiresRaw is! String) {
    throw const FormatException('direct Room join fields');
  }
  return RoomDirectJoinBundle(
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
}

/// Written out rather than taken from `index`, so reordering the enum can
/// never silently repoint an already-issued invite at the wrong kind.
/// One roster row, in field order. Written out rather than inlined in the
/// comprehension because the fields are read in sequence and a collection
/// literal does not promise that.
RoomAcceptedJoinMember _readMember(_ByteReader input, bool seats) {
  final memberId = RoomMemberId(input.hex(_memberIdBytes));
  final packed = input.u8();
  // A v2 record has no flag bits, so an unknown byte there is exactly what it
  // always was: a kind this build does not know, and a record it must refuse.
  // Checked before another byte is read: an unrecognised flag means the rest
  // of this row is not laid out the way this reader thinks, and a varint read
  // off the wrong offset would desynchronise the whole roster rather than
  // fail here.
  if (seats && packed & _memberByteMask != packed) {
    throw const FormatException('direct Room join member flags');
  }
  final kind = _readKind(seats ? packed & _memberKindMask : packed);
  final pending = seats && packed & _memberFlagPending != 0;
  final joinedAt = input.timestamp();
  final heldUntil = seats && packed & _memberFlagHeldUntil != 0
      ? input.timestamp()
      : null;
  return RoomAcceptedJoinMember(
    memberId: memberId,
    kind: kind,
    joinedAt: joinedAt,
    displayName: input.text(),
    pending: pending,
    // Never a hold without the mark: the writer refuses to emit one, and a
    // record that claims otherwise is not this format.
    heldUntil: pending ? heldUntil : null,
  );
}

int _wireKind(RoomMemberKind kind) => switch (kind) {
  RoomMemberKind.member => 0,
  RoomMemberKind.guest => 1,
};

RoomMemberKind _readKind(int wire) => switch (wire) {
  0 => RoomMemberKind.member,
  1 => RoomMemberKind.guest,
  _ => throw const FormatException('direct Room join member kind'),
};

/// Byte sink for the binary layouts.
///
/// Every integer is written with `%` and `~/` rather than shifts: on web an
/// `int` is a double and `<<` truncates to 32 bits, which would quietly
/// corrupt millisecond timestamps.
final class _ByteWriter {
  final _bytes = <int>[];

  void u8(int value) => _bytes.add(value & 0xff);

  void varint(int value) {
    if (value < 0 || value > _maxVarintValue) {
      throw const FormatException('direct Room join value out of range');
    }
    var remaining = value;
    while (remaining >= 0x80) {
      _bytes.add(remaining % 0x80 + 0x80);
      remaining = remaining ~/ 0x80;
    }
    _bytes.add(remaining);
  }

  void timestamp(DateTime value) =>
      varint(value.toUtc().millisecondsSinceEpoch);

  void fixed(List<int> value, int length) {
    if (value.length != length) {
      throw const FormatException('direct Room join field width');
    }
    for (final byte in value) {
      _bytes.add(byte & 0xff);
    }
  }

  void hex(String value, int length) {
    if (value.length != length * 2) {
      throw const FormatException('direct Room join identifier width');
    }
    for (var index = 0; index < value.length; index += 2) {
      final byte = int.tryParse(value.substring(index, index + 2), radix: 16);
      if (byte == null) {
        throw const FormatException('direct Room join identifier');
      }
      _bytes.add(byte);
    }
  }

  void text(String value) {
    final encoded = utf8.encode(value);
    if (encoded.length > _maxTextBytes) {
      throw const FormatException('direct Room join text too long');
    }
    varint(encoded.length);
    _bytes.addAll(encoded);
  }

  Uint8List take() => Uint8List.fromList(_bytes);
}

final class _ByteReader {
  _ByteReader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  int u8() {
    if (_offset >= _bytes.length) {
      throw const FormatException('direct Room join truncated');
    }
    return _bytes[_offset++];
  }

  int varint() {
    var value = 0;
    var scale = 1;
    for (var group = 0; group < _maxVarintBytes; group += 1) {
      final byte = u8();
      value += byte % 0x80 * scale;
      if (byte < 0x80) return value;
      scale *= 0x80;
    }
    throw const FormatException('direct Room join varint');
  }

  DateTime timestamp() =>
      DateTime.fromMillisecondsSinceEpoch(varint(), isUtc: true);

  List<int> fixed(int length) {
    if (_bytes.length - _offset < length) {
      throw const FormatException('direct Room join truncated');
    }
    final slice = List<int>.unmodifiable(
      _bytes.sublist(_offset, _offset + length),
    );
    _offset += length;
    return slice;
  }

  String hex(int length) {
    final out = StringBuffer();
    for (var index = 0; index < length; index += 1) {
      out.write(u8().toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  String text() {
    final length = varint();
    if (length > _maxTextBytes) {
      throw const FormatException('direct Room join text too long');
    }
    return utf8.decode(fixed(length), allowMalformed: false);
  }

  void assertExhausted() {
    if (_offset != _bytes.length) {
      throw const FormatException('direct Room join trailing bytes');
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
