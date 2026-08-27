import 'dart:convert';

import 'package:flutter/services.dart';

import '../../domain/entity/room.dart';
import '../../domain/service/room_member_transport_identity.dart';

/// Private Room transport identity material persisted only through the platform
/// secure-storage boundary.
///
/// The encoded form contains a private Ed25519 key and therefore must never be
/// placed in SharedPreferences, Room snapshots, QR payloads, diagnostics,
/// transport packets or logs. It is intentionally package-private to this
/// storage adapter's call path.
final class RoomStoredTransportIdentity {
  const RoomStoredTransportIdentity({
    required this.keyPair,
    required this.certificate,
  });

  final RoomMemberTransportKeyPair keyPair;
  final RoomMemberTransportCertificate certificate;

  String _encode() => jsonEncode({
    'v': 1,
    'privateKey': keyPair.encodedPrivateKey,
    'publicKey': keyPair.encodedPublicKey,
    'certificate': certificate.encode(),
  });

  static RoomStoredTransportIdentity? _decode(
    String encoded, {
    required RoomId expectedRoomId,
    required RoomMemberId expectedMemberId,
  }) {
    if (encoded.isEmpty || encoded.length > 8192) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> || value['v'] != 1) return null;
      final keyPair = RoomMemberTransportKeyPair.decode(
        privateKey: value['privateKey'] as String? ?? '',
        publicKey: value['publicKey'] as String? ?? '',
      );
      final certificate = RoomMemberTransportCertificate.decode(
        value['certificate'] as String? ?? '',
      );
      if (certificate.roomId != expectedRoomId ||
          certificate.memberId != expectedMemberId ||
          !_sameBytes(certificate.memberPublicKey, keyPair.publicKey)) {
        return null;
      }
      return RoomStoredTransportIdentity(
        keyPair: keyPair,
        certificate: certificate,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Android-backed secure store for the private key used by live Room member
/// proofs.
///
/// Native Android encrypts the opaque record with an AES/GCM key held by
/// AndroidKeyStore before any ciphertext is persisted. Unsupported platforms,
/// missing plugins and corrupted records fail closed to false/null rather than
/// falling back to ordinary preferences.
final class RoomTransportIdentitySecureStore {
  RoomTransportIdentitySecureStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'tark/room_identity_secure_store';
  final MethodChannel _channel;

  Future<bool> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomStoredTransportIdentity identity,
  }) async {
    if (!_matchesScope(identity, roomId, memberId)) return false;
    try {
      await _channel.invokeMethod<void>('write', {
        'roomId': roomId.value,
        'memberId': memberId.value,
        'secret': identity._encode(),
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<RoomStoredTransportIdentity?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    try {
      final encoded = await _channel.invokeMethod<String>('read', {
        'roomId': roomId.value,
        'memberId': memberId.value,
      });
      if (encoded == null) return null;
      return RoomStoredTransportIdentity._decode(
        encoded,
        expectedRoomId: roomId,
        expectedMemberId: memberId,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    try {
      await _channel.invokeMethod<void>('delete', {
        'roomId': roomId.value,
        'memberId': memberId.value,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static bool _matchesScope(
    RoomStoredTransportIdentity identity,
    RoomId roomId,
    RoomMemberId memberId,
  ) =>
      identity.certificate.roomId == roomId &&
      identity.certificate.memberId == memberId &&
      _sameBytes(identity.certificate.memberPublicKey, identity.keyPair.publicKey);
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index += 1) {
    diff |= a[index] ^ b[index];
  }
  return diff == 0;
}
