import 'package:flutter/services.dart';

import '../../domain/entity/room.dart';
import '../../domain/service/room_member_transport_identity.dart';

/// Persisted local cryptographic identity for one durable Room membership.
///
/// Private key material is intentionally kept outside Room snapshots,
/// SharedPreferences, invite payloads and diagnostics. Android production uses
/// an Android-Keystore-backed encrypted file through [_channel].
final class RoomTransportIdentityMaterial {
  const RoomTransportIdentityMaterial({
    required this.memberKeyPair,
    required this.certificate,
    this.issuerKeyPair,
  });

  final RoomMemberTransportKeyPair memberKeyPair;
  final RoomMemberTransportCertificate certificate;

  /// Present only on a device that is allowed to issue member certificates for
  /// this Room. Ordinary members persist no issuer private key.
  final RoomMemberTransportKeyPair? issuerKeyPair;

  Map<String, Object?> toMap() => {
    'memberPrivateKey': memberKeyPair.encodedPrivateKey,
    'memberPublicKey': memberKeyPair.encodedPublicKey,
    'certificate': certificate.encode(),
    if (issuerKeyPair case final issuer?)
      'issuerPrivateKey': issuer.encodedPrivateKey,
    if (issuerKeyPair case final issuer?)
      'issuerPublicKey': issuer.encodedPublicKey,
  };

  static RoomTransportIdentityMaterial fromMap(
    Map<Object?, Object?> value, {
    required RoomId roomId,
    required RoomMemberId memberId,
  }) {
    final member = RoomMemberTransportKeyPair.decode(
      privateKey: value['memberPrivateKey'] as String? ?? '',
      publicKey: value['memberPublicKey'] as String? ?? '',
    );
    final certificate = RoomMemberTransportCertificate.decode(
      value['certificate'] as String? ?? '',
    );
    if (certificate.roomId != roomId || certificate.memberId != memberId) {
      throw const FormatException('secure Room identity scope mismatch');
    }
    if (!_sameBytes(member.publicKey, certificate.memberPublicKey)) {
      throw const FormatException('secure Room member key mismatch');
    }

    RoomMemberTransportKeyPair? issuer;
    final issuerPrivate = value['issuerPrivateKey'];
    final issuerPublic = value['issuerPublicKey'];
    if (issuerPrivate != null || issuerPublic != null) {
      if (issuerPrivate is! String || issuerPublic is! String) {
        throw const FormatException('incomplete secure Room issuer key');
      }
      issuer = RoomMemberTransportKeyPair.decode(
        privateKey: issuerPrivate,
        publicKey: issuerPublic,
      );
      if (!_sameBytes(issuer.publicKey, certificate.issuerPublicKey)) {
        throw const FormatException('secure Room issuer key mismatch');
      }
    }

    return RoomTransportIdentityMaterial(
      memberKeyPair: member,
      certificate: certificate,
      issuerKeyPair: issuer,
    );
  }
}

abstract interface class RoomTransportIdentitySecureStore {
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  });

  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  });

  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  });
}

/// Android production secure storage.
///
/// The native side uses Android Keystore AES-GCM and stores only ciphertext in
/// an app-private file. Missing/corrupt/unsupported storage fails closed; this
/// class never falls back to SharedPreferences or plaintext persistence.
final class PlatformRoomTransportIdentitySecureStore
    implements RoomTransportIdentitySecureStore {
  PlatformRoomTransportIdentitySecureStore({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const _defaultChannel = MethodChannel(
    'tark/room_identity_secure_storage',
  );

  final MethodChannel _channel;

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    if (material.certificate.roomId != roomId ||
        material.certificate.memberId != memberId) {
      throw ArgumentError('Room identity material does not match storage scope');
    }
    if (!_sameBytes(
      material.memberKeyPair.publicKey,
      material.certificate.memberPublicKey,
    )) {
      throw ArgumentError('Room member private key does not match certificate');
    }
    final issuer = material.issuerKeyPair;
    if (issuer != null &&
        !_sameBytes(issuer.publicKey, material.certificate.issuerPublicKey)) {
      throw ArgumentError('Room issuer private key does not match certificate');
    }

    await _channel.invokeMethod<void>('write', {
      'roomId': roomId.value,
      'memberId': memberId.value,
      'material': material.toMap(),
    });
  }

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    final raw = await _channel.invokeMethod<Object?>('read', {
      'roomId': roomId.value,
      'memberId': memberId.value,
    });
    if (raw == null) return null;
    if (raw is! Map) {
      throw const FormatException('invalid secure Room identity payload');
    }
    return RoomTransportIdentityMaterial.fromMap(
      raw,
      roomId: roomId,
      memberId: memberId,
    );
  }

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) => _channel.invokeMethod<void>('delete', {
    'roomId': roomId.value,
    'memberId': memberId.value,
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index += 1) {
    diff |= a[index] ^ b[index];
  }
  return diff == 0;
}
