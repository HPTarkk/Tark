import 'dart:convert';
import 'dart:math';

import 'room.dart';

enum RoomInvitationKind { trustedMembership, singleRideGuest }

/// Optional connectivity bootstrap carried alongside membership capability.
/// It is deliberately a separate section so rotating hotspot credentials never
/// changes RoomId or durable membership semantics.
final class RoomTransportBootstrap {
  const RoomTransportBootstrap({required this.kind, required this.payload});

  final String kind;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {'kind': kind, 'payload': payload};

  static RoomTransportBootstrap? fromJson(Object? value) {
    if (value == null) return null;
    if (value is! Map<String, dynamic>) {
      throw const FormatException('transport bootstrap');
    }
    final kind = value['kind'];
    final payload = value['payload'];
    if (kind is! String || kind.isEmpty || payload is! Map<String, dynamic>) {
      throw const FormatException('transport bootstrap fields');
    }
    return RoomTransportBootstrap(
      kind: kind,
      payload: Map.unmodifiable(payload),
    );
  }
}

/// Versioned bearer capability used by Room QR/link invitations.
///
/// [secret] is the authorization material. [displayCode] is only a short human
/// check value and MUST NOT be accepted as proof of membership by itself.
final class RoomInvitation {
  const RoomInvitation({
    required this.version,
    required this.roomId,
    required this.invitationId,
    required this.secret,
    required this.kind,
    required this.issuedAt,
    required this.expiresAt,
    required this.singleUse,
    required this.displayCode,
    this.transportBootstrap,
  });

  static const currentVersion = 1;

  final int version;
  final RoomId roomId;
  final String invitationId;
  final String secret;
  final RoomInvitationKind kind;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final bool singleUse;
  final String displayCode;
  final RoomTransportBootstrap? transportBootstrap;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  String encode() {
    final json = jsonEncode({
      'v': version,
      'roomId': roomId.value,
      'invitationId': invitationId,
      'secret': secret,
      'kind': kind.name,
      'issuedAt': issuedAt.toUtc().toIso8601String(),
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'singleUse': singleUse,
      'displayCode': displayCode,
      if (transportBootstrap != null) 'transport': transportBootstrap!.toJson(),
    });
    return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  }

  static RoomInvitation decode(String encoded) {
    try {
      final normalized = base64Url.normalize(encoded.trim());
      final value = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (value is! Map<String, dynamic>) {
        throw const FormatException('invite object');
      }
      if (value['v'] != currentVersion) {
        throw const FormatException('unsupported invite version');
      }
      final roomId = RoomId.parse(value['roomId'] as String? ?? '');
      final invitationId = value['invitationId'];
      final secret = value['secret'];
      final kindRaw = value['kind'];
      final issuedRaw = value['issuedAt'];
      final expiresRaw = value['expiresAt'];
      final singleUse = value['singleUse'];
      final displayCode = value['displayCode'];
      if (roomId == null ||
          invitationId is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(invitationId) ||
          secret is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret) ||
          kindRaw is! String ||
          issuedRaw is! String ||
          expiresRaw is! String ||
          singleUse is! bool ||
          displayCode is! String ||
          !RegExp(r'^\d{6}$').hasMatch(displayCode)) {
        throw const FormatException('invite fields');
      }
      final kind = RoomInvitationKind.values.where(
        (item) => item.name == kindRaw,
      );
      if (kind.length != 1) throw const FormatException('invite kind');
      final issuedAt = DateTime.parse(issuedRaw).toUtc();
      final expiresAt = DateTime.parse(expiresRaw).toUtc();
      if (!expiresAt.isAfter(issuedAt)) {
        throw const FormatException('invite expiry');
      }
      final expectedCode = roomInviteDisplayCode(roomId, invitationId);
      if (displayCode != expectedCode) {
        throw const FormatException('invite display code');
      }
      return RoomInvitation(
        version: currentVersion,
        roomId: roomId,
        invitationId: invitationId,
        secret: secret,
        kind: kind.single,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
        singleUse: singleUse,
        displayCode: displayCode,
        transportBootstrap: RoomTransportBootstrap.fromJson(value['transport']),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed room invitation');
    }
  }
}

RoomInvitation generateRoomInvitation({
  required RoomId roomId,
  required RoomInvitationKind kind,
  required DateTime now,
  required Duration ttl,
  RoomTransportBootstrap? transportBootstrap,
  Random? random,
}) {
  if (ttl <= Duration.zero) throw ArgumentError.value(ttl, 'ttl');
  final rng = random ?? Random.secure();
  String hex(int length) {
    final out = StringBuffer();
    for (var i = 0; i < length; i++) {
      out.write(rng.nextInt(16).toRadixString(16));
    }
    return out.toString();
  }

  final id = hex(32);
  final issued = now.toUtc();
  return RoomInvitation(
    version: RoomInvitation.currentVersion,
    roomId: roomId,
    invitationId: id,
    secret: hex(64),
    kind: kind,
    issuedAt: issued,
    expiresAt: issued.add(ttl),
    singleUse: kind == RoomInvitationKind.singleRideGuest,
    displayCode: roomInviteDisplayCode(roomId, id),
    transportBootstrap: transportBootstrap,
  );
}

/// Six-digit verbal/check value. This intentionally contains far less entropy
/// than the bearer secret and is never an authorization credential.
String roomInviteDisplayCode(RoomId roomId, String invitationId) {
  var hash = 2166136261;
  for (final unit in '${roomId.value}:$invitationId'.codeUnits) {
    hash ^= unit;
    hash = (hash * 16777619) & 0x7fffffff;
  }
  return (hash % 1000000).toString().padLeft(6, '0');
}
