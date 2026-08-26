import 'dart:convert';

import '../entity/room.dart';
import '../entity/room_invitation.dart';
import 'room_invite_acceptance_coordinator.dart';

/// Transport-independent request/response contract for secure Room invite join.
///
/// The scanned invitation remains a bearer capability only. An issuer must
/// verify/redeem it through [RoomInviteAcceptanceCoordinator] before returning
/// an accepted response. This contract intentionally carries no Wi-Fi
/// credentials, IP address, transport role, or permanent Room secret.
final class RoomInviteJoinExchange {
  RoomInviteJoinExchange({required RoomInviteAcceptanceCoordinator acceptance})
    : _acceptance = acceptance;

  static const currentVersion = 1;
  static const maxDisplayNameLength = 80;
  static const maxEncodedRequestLength = 2048;
  static const maxEncodedResponseLength = 1024;

  final RoomInviteAcceptanceCoordinator _acceptance;

  Future<String> handleEncodedRequest(String encoded, {required DateTime now}) async {
    RoomInviteJoinRequest request;
    try {
      request = RoomInviteJoinRequest.decode(encoded);
    } on FormatException {
      return const RoomInviteJoinResponse.malformed(requestId: '').encode();
    }

    final result = await _acceptance.accept(
      invitation: request.invitation,
      displayName: request.displayName,
      now: now,
    );

    switch (result.status) {
      case RoomInviteAcceptanceStatus.accepted:
        final room = result.room!;
        final memberId = RoomMemberId(
          request.invitation.invitationId.substring(0, 24),
        );
        return RoomInviteJoinResponse.accepted(
          requestId: request.requestId,
          roomId: room.room.id,
          memberId: memberId,
        ).encode();
      case RoomInviteAcceptanceStatus.rejected:
        return RoomInviteJoinResponse.rejected(
          requestId: request.requestId,
        ).encode();
      case RoomInviteAcceptanceStatus.roomUnavailable:
        return RoomInviteJoinResponse.roomUnavailable(
          requestId: request.requestId,
        ).encode();
    }
  }
}

final class RoomInviteJoinRequest {
  const RoomInviteJoinRequest({
    required this.requestId,
    required this.invitation,
    required this.displayName,
  });

  final String requestId;
  final RoomInvitation invitation;
  final String displayName;

  String encode() {
    final cleanName = displayName.trim();
    if (!_validRequestId(requestId) ||
        cleanName.isEmpty ||
        cleanName.length > RoomInviteJoinExchange.maxDisplayNameLength) {
      throw const FormatException('invalid room join request');
    }
    final payload = jsonEncode({
      'v': RoomInviteJoinExchange.currentVersion,
      'requestId': requestId,
      'invite': invitation.encode(),
      'displayName': cleanName,
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    if (encoded.length > RoomInviteJoinExchange.maxEncodedRequestLength) {
      throw const FormatException('room join request too large');
    }
    return encoded;
  }

  static RoomInviteJoinRequest decode(String encoded) {
    final raw = encoded.trim();
    if (raw.isEmpty || raw.length > RoomInviteJoinExchange.maxEncodedRequestLength) {
      throw const FormatException('room join request size');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      );
      if (value is! Map<String, dynamic> ||
          value['v'] != RoomInviteJoinExchange.currentVersion) {
        throw const FormatException('room join request version');
      }
      final requestId = value['requestId'];
      final invite = value['invite'];
      final displayName = value['displayName'];
      if (requestId is! String ||
          !_validRequestId(requestId) ||
          invite is! String ||
          displayName is! String) {
        throw const FormatException('room join request fields');
      }
      final cleanName = displayName.trim();
      if (cleanName.isEmpty ||
          cleanName.length > RoomInviteJoinExchange.maxDisplayNameLength) {
        throw const FormatException('room join display name');
      }
      return RoomInviteJoinRequest(
        requestId: requestId,
        invitation: RoomInvitation.decode(invite),
        displayName: cleanName,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed room join request');
    }
  }

  static bool _validRequestId(String value) =>
      RegExp(r'^[0-9a-f]{32}$').hasMatch(value);
}

enum RoomInviteJoinResponseStatus {
  accepted,
  rejected,
  roomUnavailable,
  malformed,
}

final class RoomInviteJoinResponse {
  const RoomInviteJoinResponse.accepted({
    required this.requestId,
    required this.roomId,
    required this.memberId,
  }) : status = RoomInviteJoinResponseStatus.accepted;

  const RoomInviteJoinResponse.rejected({required this.requestId})
    : status = RoomInviteJoinResponseStatus.rejected,
      roomId = null,
      memberId = null;

  const RoomInviteJoinResponse.roomUnavailable({required this.requestId})
    : status = RoomInviteJoinResponseStatus.roomUnavailable,
      roomId = null,
      memberId = null;

  const RoomInviteJoinResponse.malformed({required this.requestId})
    : status = RoomInviteJoinResponseStatus.malformed,
      roomId = null,
      memberId = null;

  final String requestId;
  final RoomInviteJoinResponseStatus status;
  final RoomId? roomId;
  final RoomMemberId? memberId;

  String encode() {
    if (requestId.isNotEmpty && !RoomInviteJoinRequest._validRequestId(requestId)) {
      throw const FormatException('invalid room join response request id');
    }
    if (status == RoomInviteJoinResponseStatus.accepted &&
        (roomId == null || memberId == null)) {
      throw const FormatException('accepted room join response fields');
    }
    final payload = jsonEncode({
      'v': RoomInviteJoinExchange.currentVersion,
      'requestId': requestId,
      'status': status.name,
      if (roomId != null) 'roomId': roomId!.value,
      if (memberId != null) 'memberId': memberId!.value,
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    if (encoded.length > RoomInviteJoinExchange.maxEncodedResponseLength) {
      throw const FormatException('room join response too large');
    }
    return encoded;
  }

  static RoomInviteJoinResponse decode(String encoded) {
    final raw = encoded.trim();
    if (raw.isEmpty || raw.length > RoomInviteJoinExchange.maxEncodedResponseLength) {
      throw const FormatException('room join response size');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      );
      if (value is! Map<String, dynamic> ||
          value['v'] != RoomInviteJoinExchange.currentVersion) {
        throw const FormatException('room join response version');
      }
      final requestId = value['requestId'];
      final statusRaw = value['status'];
      if (requestId is! String ||
          (requestId.isNotEmpty && !RoomInviteJoinRequest._validRequestId(requestId)) ||
          statusRaw is! String) {
        throw const FormatException('room join response fields');
      }
      final statuses = RoomInviteJoinResponseStatus.values.where(
        (item) => item.name == statusRaw,
      );
      if (statuses.length != 1) {
        throw const FormatException('room join response status');
      }
      final status = statuses.single;
      if (status == RoomInviteJoinResponseStatus.accepted) {
        final roomId = RoomId.parse(value['roomId'] as String? ?? '');
        final memberIdRaw = value['memberId'];
        if (roomId == null ||
            memberIdRaw is! String ||
            !RegExp(r'^[0-9a-f]{24}$').hasMatch(memberIdRaw)) {
          throw const FormatException('accepted room join response identity');
        }
        return RoomInviteJoinResponse.accepted(
          requestId: requestId,
          roomId: roomId,
          memberId: RoomMemberId(memberIdRaw),
        );
      }
      if (value.containsKey('roomId') || value.containsKey('memberId')) {
        throw const FormatException('unexpected room join response identity');
      }
      return switch (status) {
        RoomInviteJoinResponseStatus.rejected =>
          RoomInviteJoinResponse.rejected(requestId: requestId),
        RoomInviteJoinResponseStatus.roomUnavailable =>
          RoomInviteJoinResponse.roomUnavailable(requestId: requestId),
        RoomInviteJoinResponseStatus.malformed =>
          RoomInviteJoinResponse.malformed(requestId: requestId),
        RoomInviteJoinResponseStatus.accepted => throw const FormatException(
          'unreachable accepted room join response',
        ),
      };
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed room join response');
    }
  }
}
