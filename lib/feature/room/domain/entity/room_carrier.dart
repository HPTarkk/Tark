import 'dart:convert';

import '../service/room_member_transport_identity.dart';
import 'room.dart';

/// Whether the network a Room is talking over is one the Room can keep.
///
/// This is the distinction the transport layer was missing, and the reason a
/// group that set up at home went silent on the road. Two riders standing in a
/// kitchen on the house Wi-Fi have a link that measures perfectly — low
/// latency, no loss, every check green — and that measurement says nothing
/// about whether the link still exists at the end of the street. "Works right
/// now" and "will keep working" are different properties, and only the second
/// one is worth planning around.
enum RoomCarrierDurability {
  /// The Room owns its carrier: a member's hotspot, or a radio link between
  /// the phones themselves. Nothing outside the group can take it away, so it
  /// travels with the group.
  owned,

  /// The Room is borrowing somebody else's access point — home, office, a
  /// café. Excellent while you are inside it and gone at the property line,
  /// with no warning and no handover.
  ///
  /// Treated as a *bootstrap*, never a destination: it is the ideal way to get
  /// everyone introduced and to carry the credentials for the carrier they
  /// will actually leave on.
  borrowed;

  bool get isBorrowed => this == RoomCarrierDurability.borrowed;
}

/// A signed instruction to move the whole Room onto a new carrier.
///
/// Broadcast by the elected hotspot host over the carrier that is *still
/// working*, which is the entire point. The old design only ever changed
/// carrier after the current one failed, and at that moment there is no path
/// left to tell anybody where to go — which is exactly how one phone ended up
/// alone on Bluetooth while the other sat alone on Wi-Fi, each transmitting
/// into nothing. Announcing the move while the group is still together, still
/// stationary and still in range turns a recovery into a handover.
///
/// ## What is signed, and what is not
///
/// The whole announcement is signed by the host's Room member key and carries
/// the host's certificate, so every receiver can chain it to the Room issuer
/// key it already holds. That closes the attack that matters here: without a
/// signature, anybody within earshot of the network could tell the group to
/// move onto an access point they control.
///
/// The passphrase itself travels in the clear, and that is a deliberate
/// judgement rather than an omission. Anyone positioned to read this message
/// is already on the shared network the Room is currently talking over, where
/// the voice traffic is broadcast UDP they can already hear — so withholding
/// the passphrase protects nothing they do not already have. And joining the
/// new access point does not make them a member: membership still runs through
/// the certificate and route-proof machinery, which an outsider cannot forge.
/// Confidentiality would cost a key exchange and buy nothing; integrity is
/// what was actually load-bearing, and that is what is here.
final class RoomCarrierHandover {
  const RoomCarrierHandover({
    required this.certificate,
    required this.generation,
    required this.ssid,
    required this.passphrase,
    required this.issuedAt,
    required this.hostSignature,
  });

  static const currentVersion = 1;
  static const maxEncodedLength = 2048;
  static const maxSsidLength = 64;
  static const maxPassphraseLength = 128;

  /// How long an announcement stays actionable.
  ///
  /// Short, because it is replayed continuously while the promotion is in
  /// flight and its only job is to survive the seconds between the host
  /// raising its access point and the last peer associating. A stale one
  /// picked up later would steer a phone at a network that no longer exists —
  /// Android rotates local-only hotspot credentials on every start.
  static const freshness = Duration(minutes: 2);

  /// The host's Room membership certificate, so this verifies on its own.
  final RoomMemberTransportCertificate certificate;

  /// Which carrier this is. Monotonic per Room session; a receiver ignores
  /// anything that is not strictly newer than the carrier it is already on,
  /// which is what stops two simultaneous elections from ping-ponging the
  /// group between two access points.
  final int generation;

  final String ssid;
  final String passphrase;
  final DateTime issuedAt;
  final List<int> hostSignature;

  RoomId get roomId => certificate.roomId;

  RoomMemberId get hostMemberId => certificate.memberId;

  bool isFresh(DateTime now) {
    final age = now.toUtc().difference(issuedAt.toUtc());
    // Negative ages are a clock disagreement, not evidence of freshness. A
    // phone whose clock runs behind the host's would otherwise accept an
    // announcement forever.
    return !age.isNegative && age <= freshness;
  }

  String encode() {
    if (ssid.isEmpty || ssid.length > maxSsidLength) {
      throw const FormatException('carrier handover ssid');
    }
    if (passphrase.isEmpty || passphrase.length > maxPassphraseLength) {
      throw const FormatException('carrier handover passphrase');
    }
    if (generation < 0 || generation > 0xFFFFFFFF) {
      throw const FormatException('carrier handover generation');
    }
    if (hostSignature.isEmpty) {
      throw const FormatException('carrier handover signature');
    }
    final payload = jsonEncode({
      'v': currentVersion,
      'cert': certificate.encode(),
      'gen': generation,
      'ssid': ssid,
      'pass': passphrase,
      'at': issuedAt.toUtc().toIso8601String(),
      'sig': base64Url.encode(hostSignature).replaceAll('=', ''),
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('carrier handover too large');
    }
    return encoded;
  }

  static RoomCarrierHandover decode(String encoded) {
    final raw = encoded.trim();
    if (raw.isEmpty || raw.length > maxEncodedLength) {
      throw const FormatException('carrier handover size');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      );
      if (value is! Map<String, dynamic> || value['v'] != currentVersion) {
        throw const FormatException('carrier handover version');
      }
      final cert = value['cert'];
      final gen = value['gen'];
      final ssid = value['ssid'];
      final pass = value['pass'];
      final at = value['at'];
      final sig = value['sig'];
      if (cert is! String ||
          gen is! int ||
          gen < 0 ||
          gen > 0xFFFFFFFF ||
          ssid is! String ||
          ssid.isEmpty ||
          ssid.length > maxSsidLength ||
          pass is! String ||
          pass.isEmpty ||
          pass.length > maxPassphraseLength ||
          at is! String ||
          sig is! String ||
          sig.isEmpty) {
        throw const FormatException('carrier handover fields');
      }
      return RoomCarrierHandover(
        certificate: RoomMemberTransportCertificate.decode(cert),
        generation: gen,
        ssid: ssid,
        passphrase: pass,
        issuedAt: DateTime.parse(at).toUtc(),
        hostSignature: List.unmodifiable(
          base64Url.decode(base64Url.normalize(sig)),
        ),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed carrier handover');
    }
  }
}
