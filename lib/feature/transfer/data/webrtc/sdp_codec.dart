import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Packs a session description (offer/answer, LAN candidates included) into
/// a QR-friendly string: JSON → zlib → base64url. A full audio SDP is
/// 1–3 KB; compressed it lands around 500–900 chars, which scans reliably
/// from a phone screen.
String encodeSessionDescription(RTCSessionDescription description) {
  final json = jsonEncode({'t': description.type, 's': description.sdp});
  final compressed = const ZLibEncoder().encode(utf8.encode(json));
  return base64UrlEncode(compressed);
}

RTCSessionDescription decodeSessionDescription(String payload) {
  final compressed = base64Url.decode(base64.normalize(payload));
  final json = utf8.decode(const ZLibDecoder().decodeBytes(compressed));
  final map = jsonDecode(json) as Map<String, dynamic>;
  return RTCSessionDescription(map['s'] as String, map['t'] as String);
}
