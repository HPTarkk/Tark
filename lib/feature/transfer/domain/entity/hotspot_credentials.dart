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
  /// payload** rather than as a second code on screen. This is the whole of
  /// the "unified QR": the format is a list of `KEY:value;` pairs and every
  /// scanner in the world skips keys it does not know — which is not an
  /// assumption but the format's own history, since WPA3 added `K:` and every
  /// pre-existing scanner had to keep working. So the system camera still
  /// offers its one-tap "join this network" and ignores the channel, while
  /// Tarkk's scanner reads both. Making the payload Tarkk-specific instead
  /// would have bought the channel at the cost of that one-tap path, which is
  /// the fastest route onto a hotspot the app has.
  ///
  /// The version lives in the *key* (`TARK1`) rather than in the value, so a
  /// future format change is an unknown key to this build — ignored, falling
  /// back to an open channel — instead of a value it would misparse.
  String qrPayload({ChannelId channel = ChannelId.open}) {
    final s = _escape(ssid);
    final p = _escape(passphrase);
    final code = channel.code;
    final tark = code == null ? '' : '$_channelKey:$code;';
    return 'WIFI:S:$s;T:$security;P:$p;H:false;$tark;';
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
  /// `TARK1` ride inside a Wi-Fi payload, and it is the same tolerance every
  /// other scanner has to have for us to ride there in the first place.
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
/// The two halves are independent on purpose, because all four combinations
/// genuinely occur:
///
///  * **network + channel** — a host on this build, the ordinary case
///  * **network only** — a host on an older build, or any Wi-Fi QR printed on
///    a café wall; joins the network and stays on the open channel
///  * **channel only** — two phones already on one network, where the only
///    thing worth passing across is which conversation to be in
///  * **neither** — not our code at all, and [parse] answers null
class ScannedCode {
  const ScannedCode({required this.credentials, required this.channel});

  /// The network to join, or null when the code carried none.
  final HotspotCredentials? credentials;

  /// The channel to adopt, or [ChannelId.open] when the code named none.
  final ChannelId channel;

  /// Reads either payload shape, or returns null for anything that is neither.
  ///
  /// A `TARK1` field whose value is not a valid code is treated as no channel
  /// rather than as a failure: the network half of the same payload is still
  /// perfectly usable, and refusing the whole scan over a garbled extension
  /// would turn a working join into a dead end.
  static ScannedCode? parse(String raw) {
    final trimmed = raw.trim();
    final upper = trimmed.toUpperCase();

    if (upper.startsWith('WIFI:')) {
      final fields = HotspotCredentials._fields(trimmed.substring(5));
      final ssid = fields['S'];
      if (ssid == null || ssid.isEmpty) return null;
      final type = fields['T'];
      return ScannedCode(
        credentials: HotspotCredentials(
          ssid: ssid,
          passphrase: fields['P'] ?? '',
          security: (type == null || type.isEmpty) ? 'WPA' : type,
        ),
        channel: _channelFrom(fields),
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
