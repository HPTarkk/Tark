import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Google's free public STUN server — lets ICE discover each side's public
/// (server-reflexive) address so the Guest link can connect two devices that
/// aren't on the same LAN, not just host-only candidates. No TURN relay
/// (that needs hosted infrastructure = a real backend cost, which this
/// project deliberately avoids), so this gets P2P working for most
/// home/mobile NAT pairings but can still fail for strict/symmetric NAT with
/// no fallback — surfaced as connectivity caveats in the guest-link UI
/// rather than hidden.
const List<Map<String, dynamic>> kIceServers = [
  {'urls': 'stun:stun.l.google.com:19302'},
];

/// Waits for ICE gathering to finish (or [timeout] to elapse, whichever
/// first) before treating an offer/answer as complete — both sides are
/// non-trickle, so there's no signaling channel to carry late candidates.
/// 4s was enough when gathering only had to enumerate near-instant LAN-only
/// host candidates; now that [kIceServers] adds a real network round-trip
/// for server-reflexive candidates, this needs more slack. A timeout never
/// throws — it just proceeds with whatever candidates gathered so far,
/// degrading gracefully rather than failing.
Future<void> waitIceGathering(
  RTCPeerConnection pc, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (pc.iceGatheringState ==
      RTCIceGatheringState.RTCIceGatheringStateComplete) {
    return;
  }
  final completer = Completer<void>();
  pc.onIceGatheringState = (state) {
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !completer.isCompleted) {
      completer.complete();
    }
  };
  await completer.future.timeout(timeout, onTimeout: () {});
}
