import 'package:equatable/equatable.dart';

import '../../../../core/identity/channel_id.dart';

/// Credentials for the local Wi-Fi hotspot an Android host creates so an
/// iPhone (or any device) can join and share the LAN the walkie-talkie runs
/// over. Produced by the native `tark/hotspot` channel.
class HotspotCredentials extends Equatable {
  final String ssid;
  final String passphrase;

  /// Wi-Fi QR `T:` security value, as reported by the host's SoftAP config:
  /// `WPA` (WPA2 or WPA3-transition — both take a WPA2 passphrase), `SAE`
  /// (WPA3-only) or `nopass`. The joining peer needs it to build the right
  /// [WifiNetworkSpecifier]; a WPA2 passphrase offered to a SAE-only AP just
  /// fails to associate.
  final String security;

  const HotspotCredentials({
    required this.ssid,
    required this.passphrase,
    this.security = 'WPA',
  });

  /// A standard Wi-Fi network QR payload. iOS Camera and Android's built-in
  /// scanner both offer a one-tap "Join this network" when they read this;
  /// the app's own scanner reads the same payload. `H:false` = not a hidden
  /// network.
  ///
  /// Special characters in the SSID/passphrase (`\ ; , : "`) must be
  /// backslash-escaped per the Wi-Fi QR spec, or a value containing them
  /// would be parsed as a field separator.
  ///
  /// [channel], when named, rides along as a `TARK1:` field **inside the same
  /// payload** rather than as a second code on screen. [roomInvite], when
  /// supplied, does the same for the durable Room handoff under `TARKROOM1:`.
  /// This is #186's one-scan late-join path: Tark's scanner persists Room
  /// membership first and then hands this *same already-scanned payload* to
  /// the hotspot joiner, so nobody has to scan a second Wi-Fi QR.
  ///
  /// Both extensions are ignored by ordinary system Wi-Fi scanners. That is
  /// deliberate compatibility: the payload stays a normal `WIFI:` code, so a
  /// non-Tark scanner can still join the network while Tark gets the extra
  /// local metadata it understands.
  ///
  /// The version lives in each key (`TARK1`, `TARKROOM1`) rather than in the
  /// value, so a future format change is an unknown key to this build —
  /// ignored instead of misparsed.
  String qrPayload({
    ChannelId channel = ChannelId.open,
    String? roomInvite,
  }) {
    final s = _escape(ssid);
    final p = _escape(passphrase);
    final code = channel.code;
    final tark = code == null ? '' : '$_channelKey:$code;';
    final room = roomInvite == null || roomInvite.trim().isEmpty
        ? ''
        : '$_roomKey:${_escape(roomInvite.trim())};';
    return 'WIFI:S:$s;T:$security;P:$p;H:false;$tark$room;';
  }

  /// Kept for the many call sites that only ever wanted the network.
  String get wifiQrPayload => qrPayload();

  /// The channel on its own, for a code that has no network to hand over —
  /// plain Wi-Fi, where both phones are already on one and the only thing
  /// worth passing across is which conversation to be in.
  ///
  /// Deliberately the same `TARK1:A83F21` token that appears inside the Wi-Fi
  /// payload above, so there is one thing to write and one thing to parse
  /// rather than two formats that can drift apart.
  static String channelOnlyPayload(ChannelId channel) =>
      '$_channelKey:${channel.code ?? ''}';

  static const _channelKey = 'TARK1';
  static const _roomKey = 'TARKROOM1';

  static String _escape(String value) =>
      value.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');

  /// Parses a standard `WIFI:S:..;T:..;P:..;;` QR payload back into
  /// credentials (the iPhone scans the Android host's QR). Returns null if the
  /// payload isn't a Wi-Fi QR or has no SSID. Honours the spec's backslash
  /// escaping so an SSID/password containing `;` `:` `,` `"` survives.
  static HotspotCredentials? fromWifiQr(String raw) =>
      ScannedCode.parse(raw)?.credentials;

  /// Splits a `KEY:value;` payload into its fields, upper-casing the keys.
  ///
  /// Unknown keys are kept rather than rejected — that tolerance is what lets
  /// `TARK1`/`TARKROOM1` ride inside a Wi-Fi payload, and it is the same
  /// tolerance every other scanner has to have for us to ride there in the
  /// first place.
  static Map<String, String> _fields(String body) {
    final fields = <String, String>{};
    final buffer = StringBuffer();
    String? key;
    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (ch == '\\' && i + 1 < body.length) {
        buffer.write(body[++i]); // escaped char — keep the next literally
      } else if (ch == ':' && key == null) {
        key = buffer.toString();
        buffer.clear();
      } else if (ch == ';') {
        if (key != null) fields[key.toUpperCase()] = buffer.toString();
        key = null;
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    if (key != null && buffer.isNotEmpty) {
      fields[key.toUpperCase()] = buffer.toString();
    }
    return fields;
  }

  @override
  List<Object?> get props => [ssid, passphrase, security];
}

/// Everything one scanned code can hand over.
///
/// The network/channel halves remain independent. A Room invite is another
/// optional extension rather than a replacement transport format: it exists
/// only when the QR was minted from an active Room hotspot and lets Tark turn
/// one camera scan into durable membership + transport attachment.
class ScannedCode {
  const ScannedCode({
    required this.credentials,
    required this.channel,
    this.roomInvite,
  });

  /// The network to join, or null when the code carried none.
  final HotspotCredentials? credentials;

  /// The channel to adopt, or [ChannelId.open] when the code named none.
  final ChannelId channel;

  /// Opaque durable Room invite carried by a Tark-aware Wi-Fi QR.
  ///
  /// Transfer never decodes this value; the Room feature remains the authority
  /// over membership/certificates and validates it before transport is acted
  /// on. Keeping it opaque here avoids coupling transport to Room internals.
  final String? roomInvite;

  /// Reads either payload shape, or returns null for anything that is neither.
  ///
  /// A `TARK1` field whose value is not a valid code is treated as no channel
  /// rather than as a failure: the network half of the same payload is still
  /// perfectly usable, and refusing the whole scan over a garbled extension
  /// would turn a working join into a dead end. `TARKROOM1` is kept opaque for
  /// the same reason; Room decides whether it is a valid invite.
  static ScannedCode? parse(String raw) {
    final trimmed = raw.trim();
    final upper = trimmed.toUpperCase();

    if (upper.startsWith('WIFI:')) {
      final fields = HotspotCredentials._fields(trimmed.substring(5));
      final ssid = fields['S'];
      if (ssid == null || ssid.isEmpty) return null;
      final type = fields['T'];
      final roomInvite = fields[HotspotCredentials._roomKey]?.trim();
      return ScannedCode(
        credentials: HotspotCredentials(
          ssid: ssid,
          passphrase: fields['P'] ?? '',
          security: (type == null || type.isEmpty) ? 'WPA' : type,
        ),
        channel: _channelFrom(fields),
        roomInvite: roomInvite == null || roomInvite.isEmpty ? null : roomInvite,
      );
    }

    if (upper.startsWith('${HotspotCredentials._channelKey}:')) {
      final channel = ChannelId.parse(
        trimmed.substring(HotspotCredentials._channelKey.length + 1),
      );
      if (channel == null) return null;
      return ScannedCode(credentials: null, channel: channel);
    }

    return null;
  }

  static ChannelId _channelFrom(Map<String, String> fields) {
    final raw = fields[HotspotCredentials._channelKey];
    if (raw == null) return ChannelId.open;
    return ChannelId.parse(raw) ?? ChannelId.open;
  }
}
