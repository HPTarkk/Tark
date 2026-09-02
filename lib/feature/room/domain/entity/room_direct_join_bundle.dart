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
/// `tark-room:` followed by unpadded base64url. Version 2 packs a compact
/// binary record; version 1 packed a JSON envelope, and is still read so a
/// code minted by an older build keeps working. Only v2 is ever written.
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

  /// The layout this build writes.
  static const currentVersion = 2;

  /// The JSON envelope earlier builds wrote. Read, never written.
  static const legacyVersion = 1;

  static const maxEncodedLength = 12288;

  /// Longest payload that still earns the centre brand mark.
  ///
  /// The mark needs error-correction level Q to survive, and Q costs modules —
  /// so the question is never "does it fit" but "can a camera still resolve
  /// it". At 460 bytes a level-Q code is 97 modules, about 2.6 logical pixels
  /// each at the 250 px the invite sheet renders, against the 1.8 that made
  /// the v1 code hard to scan.
  ///
  /// Past that the code goes out unbranded, which costs nothing but the logo:
  /// level L fits far more into the same modules, so the *unbranded* four-seat
  /// code is 77 modules — easier to scan than the branded three-seat one, not
  /// harder. The mark is the only thing ever traded away here.
  ///
  /// A bundle costs roughly 290 bytes plus 58 per member, so this covers a
  /// three-seat room.
  static const brandableEncodedLength = 460;

  static const _scheme = 'tark-room:';

  final RoomMemberId memberId;
  final RoomAcceptedJoinSnapshot snapshot;
  final RoomMemberTransportKeyPair memberKeyPair;
  final RoomMemberTransportCertificate certificate;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  String encode() {
    _assertConsistent();
    final encoded = base64Url.encode(_writeV2(this)).replaceAll('=', '');
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('direct Room join QR too large');
    }
    return '$_scheme$encoded';
  }

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
      // v1 is JSON, so its first byte is always `{`. The two layouts can never
      // be confused for one another by their leading byte.
      final bundle = bytes.isNotEmpty && bytes.first == currentVersion
          ? _readV2(Uint8List.fromList(bytes))
          : _readV1(bytes);
      // Re-run all cross-field checks in one canonical place, whichever
      // layout the bytes arrived in.
      bundle._assertConsistent();
      if (bundle.isExpired) throw const FormatException('Room invite expired');
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

Uint8List _writeV2(RoomDirectJoinBundle bundle) {
  final snapshot = bundle.snapshot;
  final out = _ByteWriter()
    ..u8(RoomDirectJoinBundle.currentVersion)
    ..u8(snapshot.grantsInviteManagement ? _flagGrantsInviteManagement : 0)
    ..hex(snapshot.roomId.value, _roomIdBytes)
    ..hex(bundle.memberId.value, _memberIdBytes)
    ..fixed(bundle.memberKeyPair.privateKey, _keyBytes)
    ..fixed(bundle.memberKeyPair.publicKey, _keyBytes)
    ..fixed(bundle.certificate.issuerPublicKey, _keyBytes)
    ..fixed(bundle.certificate.issuerSignature, _signatureBytes)
    ..timestamp(bundle.expiresAt)
    ..timestamp(snapshot.roomCreatedAt)
    ..timestamp(snapshot.roomUpdatedAt)
    ..text(snapshot.roomName)
    ..varint(snapshot.members.length);
  for (final member in snapshot.members) {
    out
      ..hex(member.memberId.value, _memberIdBytes)
      ..u8(_wireKind(member.kind))
      ..timestamp(member.joinedAt)
      ..text(member.displayName);
  }
  return out.take();
}

RoomDirectJoinBundle _readV2(Uint8List bytes) {
  final input = _ByteReader(bytes);
  input.u8(); // Version, already matched by the caller.
  final flags = input.u8();
  final roomId = RoomId(input.hex(_roomIdBytes));
  final memberId = RoomMemberId(input.hex(_memberIdBytes));
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: input.fixed(_keyBytes),
    publicKey: input.fixed(_keyBytes),
  );
  final certificate = RoomMemberTransportCertificate(
    roomId: roomId,
    memberId: memberId,
    memberPublicKey: keyPair.publicKey,
    issuerPublicKey: input.fixed(_keyBytes),
    issuerSignature: input.fixed(_signatureBytes),
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
    for (var index = 0; index < count; index += 1)
      RoomAcceptedJoinMember(
        memberId: RoomMemberId(input.hex(_memberIdBytes)),
        kind: _readKind(input.u8()),
        joinedAt: input.timestamp(),
        displayName: input.text(),
      ),
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
int _wireKind(RoomMemberKind kind) => switch (kind) {
  RoomMemberKind.member => 0,
  RoomMemberKind.guest => 1,
};

RoomMemberKind _readKind(int wire) => switch (wire) {
  0 => RoomMemberKind.member,
  1 => RoomMemberKind.guest,
  _ => throw const FormatException('direct Room join member kind'),
};

/// Byte sink for the v2 layout.
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
