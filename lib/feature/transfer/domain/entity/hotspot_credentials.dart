import 'package:equatable/equatable.dart';

/// Credentials for the local Wi-Fi hotspot an Android host creates so an
/// iPhone (or any device) can join and share the LAN the walkie-talkie runs
/// over. Produced by the native `tark/hotspot` channel.
class HotspotCredentials extends Equatable {
  final String ssid;
  final String passphrase;

  const HotspotCredentials({required this.ssid, required this.passphrase});

  /// A standard Wi-Fi network QR payload. iOS Camera and Android's built-in
  /// scanner both offer a one-tap "Join this network" when they read this.
  /// `WPA` covers WPA2/WPA3 personal (what LocalOnlyHotspot uses); `H:false`
  /// = not a hidden network.
  ///
  /// Special characters in the SSID/passphrase (`\ ; , : "`) must be
  /// backslash-escaped per the Wi-Fi QR spec, or a value containing them
  /// would be parsed as a field separator.
  String get wifiQrPayload {
    final s = _escape(ssid);
    final p = _escape(passphrase);
    return 'WIFI:S:$s;T:WPA;P:$p;H:false;;';
  }

  static String _escape(String value) => value.replaceAllMapped(
        RegExp(r'([\\;,:"])'),
        (m) => '\\${m[1]}',
      );

  /// Parses a standard `WIFI:S:..;T:..;P:..;;` QR payload back into
  /// credentials (the iPhone scans the Android host's QR). Returns null if the
  /// payload isn't a Wi-Fi QR or has no SSID. Honours the spec's backslash
  /// escaping so an SSID/password containing `;` `:` `,` `"` survives.
  static HotspotCredentials? fromWifiQr(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.toUpperCase().startsWith('WIFI:')) return null;
    final body = trimmed.substring(5);

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

    final ssid = fields['S'];
    if (ssid == null || ssid.isEmpty) return null;
    return HotspotCredentials(ssid: ssid, passphrase: fields['P'] ?? '');
  }

  @override
  List<Object?> get props => [ssid, passphrase];
}
