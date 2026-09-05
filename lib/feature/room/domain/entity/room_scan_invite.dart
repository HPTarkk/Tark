import 'dart:convert';

import 'room_direct_join_bundle.dart';

/// The QR payload scanned by the normal Room join flow.
///
/// A plain [RoomDirectJoinBundle] remains the canonical durable-membership
/// handoff and is still accepted byte-for-byte. When an inviter currently has
/// an ephemeral transport bootstrap (for example an active local hotspot),
/// this envelope carries that bootstrap beside the membership bundle in the
/// *same* Tark QR. The bootstrap is deliberately not part of Room identity or
/// persistence; it is only a hint for the joining phone after membership has
/// already been saved.
///
/// Wire shape for the one-scan variant:
///
/// `tark-room-auto:<direct-bundle-base64>.<bootstrap-base64url>`
///
/// The direct bundle is the exact payload after `tark-room:`. Splitting the two
/// base64url-safe fields with `.` avoids a second JSON/base64 expansion and
/// keeps the screen-to-screen QR materially smaller. Old `tark-room:` codes
/// remain readable by this class, so previously issued invites keep working.
final class RoomScanInvite {
  const RoomScanInvite({required this.bundle, this.transportBootstrap});

  static const _directScheme = 'tark-room:';
  static const _autoScheme = 'tark-room-auto:';
  static const maxEncodedLength = 16384;

  final RoomDirectJoinBundle bundle;

  /// Ephemeral transport data consumed only after [bundle] has been imported.
  /// Never persist this into the durable Room repository.
  final String? transportBootstrap;

  String encode() {
    final bootstrap = transportBootstrap;
    if (bootstrap == null) return bundle.encode();
    if (bootstrap.isEmpty) {
      throw const FormatException('empty Room transport bootstrap');
    }

    final direct = bundle.encode();
    final directBody = direct.substring(_directScheme.length);
    final bootstrapBody = base64Url
        .encode(utf8.encode(bootstrap))
        .replaceAll('=', '');
    final encoded = '$_autoScheme$directBody.$bootstrapBody';
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('one-scan Room invite too large');
    }
    return encoded;
  }

  static bool looksLikeInvite(String raw) {
    final value = raw.trim();
    return value.startsWith(_directScheme) || value.startsWith(_autoScheme);
  }

  static RoomScanInvite decode(String raw) {
    final value = raw.trim();
    if (value.startsWith(_directScheme)) {
      return RoomScanInvite(bundle: RoomDirectJoinBundle.decode(value));
    }
    if (!value.startsWith(_autoScheme) || value.length > maxEncodedLength) {
      throw const FormatException('not a one-scan Room invite');
    }

    final body = value.substring(_autoScheme.length);
    final separator = body.indexOf('.');
    if (separator <= 0 || separator == body.length - 1) {
      throw const FormatException('malformed one-scan Room invite');
    }
    // Exactly one separator. Accepting another would make the bootstrap field
    // ambiguous and would hide trailing garbage that should fail closed.
    if (body.indexOf('.', separator + 1) != -1) {
      throw const FormatException('malformed one-scan Room invite');
    }

    try {
      final bundle = RoomDirectJoinBundle.decode(
        '$_directScheme${body.substring(0, separator)}',
      );
      final bootstrap = utf8.decode(
        base64Url.decode(base64Url.normalize(body.substring(separator + 1))),
        allowMalformed: false,
      );
      if (bootstrap.isEmpty) {
        throw const FormatException('empty Room transport bootstrap');
      }
      return RoomScanInvite(
        bundle: bundle,
        transportBootstrap: bootstrap,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed one-scan Room invite');
    }
  }
}
