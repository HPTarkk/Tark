/// Pulls the payload out of whatever was scanned/opened: a bare payload, a
/// full invite URL (`https://host/#o=<payload>`), or a reply URL fragment
/// (`a=<payload>`). Returns null when nothing usable is found.
///
/// Pure string parsing — lives in domain (unlike the WebRTC-bound SDP
/// encode/decode in data/webrtc/sdp_codec.dart) so presentation can use it
/// without reaching into the data layer.
String? extractSdpPayload(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final fragmentMarker = text.indexOf('#');
  final fragment = fragmentMarker >= 0
      ? text.substring(fragmentMarker + 1)
      : text;
  for (final prefix in ['o=', 'a=']) {
    if (fragment.startsWith(prefix)) return fragment.substring(prefix.length);
  }
  return fragment;
}
