import 'dart:math';

import '../../../transfer/api/transfer_api.dart';

/// The half of a one-scan Room invite that is not membership: how the
/// scanning phone reaches the phone that showed the code.
///
/// One scan has to be enough. Membership alone left the new member in a Room
/// with nobody to talk to — a freshly created Room has no network up yet — so
/// the issuer brings its link up *before* the code is shown and the code
/// carries both. Which link is the issuer's selected connection type.
sealed class RoomInviteLink {
  const RoomInviteLink();

  /// The QR payload carrying [roomInvite] together with this link.
  String payload(String roomInvite);
}

/// The issuer is hosting a hotspot. The payload stays a standard `WIFI:` code
/// (any camera app can still join the network), with the Room invite as a
/// Tark field inside it.
final class HotspotInviteLink extends RoomInviteLink {
  const HotspotInviteLink(this.credentials);

  final HotspotCredentials credentials;

  @override
  String payload(String roomInvite) =>
      credentials.qrPayload(roomInvite: roomInvite);
}

/// The issuer is waiting on Bluetooth. Android hides a phone's own Bluetooth
/// address from apps, so the code cannot carry one: it carries a random
/// rendezvous [token] instead, which the issuer advertises and the scanner
/// looks for, then dials.
final class BluetoothInviteLink extends RoomInviteLink {
  BluetoothInviteLink(this.token) {
    if (!_token.hasMatch(token)) {
      throw const FormatException('invalid Bluetooth rendezvous token');
    }
  }

  /// A fresh token for one invite.
  factory BluetoothInviteLink.fresh([Random? random]) {
    final source = random ?? Random.secure();
    final token = List<String>.generate(
      16,
      (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return BluetoothInviteLink(token);
  }

  final String token;

  static const _scheme = 'tark-bt1:';
  static final _token = RegExp(r'^[0-9a-f]{32}$');

  @override
  String payload(String roomInvite) => '$_scheme$token:${roomInvite.trim()}';

  /// Splits a scanned Bluetooth invite into its link and the Room invite, or
  /// returns null when [raw] is not one.
  static ({BluetoothInviteLink link, String roomInvite})? tryParse(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith(_scheme)) return null;
    final rest = trimmed.substring(_scheme.length);
    final split = rest.indexOf(':');
    if (split <= 0) return null;
    final token = rest.substring(0, split);
    if (!_token.hasMatch(token)) return null;
    final roomInvite = rest.substring(split + 1);
    if (roomInvite.isEmpty) return null;
    return (link: BluetoothInviteLink(token), roomInvite: roomInvite);
  }
}
