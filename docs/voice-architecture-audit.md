# Voice architecture audit

## Current architecture

Tark is a Flutter/Dart app with Android/iOS native bridges and vendored native audio/noise packages. The app uses clean architecture with feature APIs, BLoC/Cubit, `injectable`/`get_it`, and `go_router`. The voice session is split into an audio feature (`AudioEngine`) and transfer repositories that share one wire codec.

## Audio path

The microphone is opened through the vendored `audio_io` plugin. Android voice-call routing is configured before stream startup, then AEC/NS/AGC are attached to the native capture session where available. Captured device-rate audio is low-pass filtered, resampled to 16 kHz mono, noise-suppressed, cut into 20 ms frames, gated with VOX hangover/pre-roll in `WalkieTalkieCubit`, encoded with Opus when libopus is available, and decoded into a per-sender jitter buffer before playback. The default playback target buffer is 100 ms.

## Existing transports

* Wi-Fi/LAN/hotspot: UDP port 4000 with directed broadcast, limited broadcast, unicast to recently heard peers, and a /24 unicast discovery sweep for iOS/local-network broadcast limitations. Hotspot setup is Android LocalOnlyHotspot; audio itself still uses Wi-Fi UDP.
* Bluetooth: Android Classic RFCOMM/SPP plus BLE GATT; Classic uses length-prefixed stream framing in Dart, BLE chunks to negotiated ATT MTU in its engine.
* Guest/WebRTC: existing WebRTC data-channel guest link using public STUN and one-shot QR/link SDP signaling. This is not yet the recommended native-app audio path because it carries custom Waki packets over a data channel rather than WebRTC media audio, TURN fallback, or SFU rooms.
* No Wi-Fi Direct implementation was found.

## Bottlenecks and likely causes

* Latency is most likely from the sum of 20 ms capture frames, Opus encode/decode, VOX hangover for transmit state, target jitter buffer, Bluetooth retransmission/queueing, and platform Bluetooth SCO/HFP audio routing latency. BLE is especially fragile for continuous audio even with Opus.
* Bluetooth disconnects are likely a mix of OS radio policy, plugin/permission differences, BLE background advertising/scanning limits, RFCOMM stream closure, headset-vs-phone Bluetooth profile contention, and reconnect state that is role-based but still not a full transport/session state machine.
* Wi-Fi disconnects are likely from OS network changes, hotspot DHCP/IP changes, socket lifecycle, Doze/battery saver, multicast/broadcast suppression, and heartbeat/liveness gaps. The code already mitigates several with socket rebinding, wake/Wi-Fi/multicast locks, and peer unicast.
* WebRTC guest reconnect is bounded and cannot fully renegotiate after one-shot signaling; that is a product/architecture limitation, not a small bug.

## Recommended product architecture

Use a hybrid architecture with explicit transport abstraction and session identity:

1. **Same-bike mode:** local LAN/hotspot first. Prefer encrypted WebRTC media over LAN or RTP/UDP with SRTP/DTLS and Opus if implementing media stack manually. Keep Android hotspot as setup; avoid relying on iOS hotspot hosting.
2. **Online room mode:** native-app WebRTC media with Opus mono, ICE, STUN, TURN fallback, adaptive jitter, packet-loss concealment, and SFU for groups. This should replace the current guest-only data-channel audio path for internet rooms.
3. **Bluetooth fallback:** keep Android Classic for emergency two-device fallback only; BLE should be treated as compatibility/fallback, not the primary low-latency stable path.
4. **Transport manager:** introduce `LocalTransport`, `InternetTransport`, `BluetoothTransport`, `TransportManager`, `ConnectionStateMachine`, and `SessionManager` so the audio session and room identity survive network changes without creating a new room.

## Scenario comparison

| Scenario | Fit | Latency | Stability | Battery | Internet | Background |
|---|---|---:|---|---|---|---|
| WebRTC media + Opus + TURN/SFU | Best for remote/group | ~80-250 ms P2P, higher via TURN/SFU | High with TURN/SFU | Medium | Yes except LAN ICE | Good with foreground/audio background setup |
| Hotspot/LAN local | Best same-bike | ~60-180 ms depending buffer | Medium-high with locks/rebind | Medium-high for hotspot host | No | Android good with FGS/locks; iOS constrained |
| Wi-Fi Direct | Android-only niche | ~60-180 ms | Device/version dependent | Medium-high | No | Poor/complex | 
| Bluetooth Classic/BLE direct | Fallback only | Classic variable; BLE often high/jittery | Device/profile dependent | Low-medium | No | OS-limited, especially iOS BLE |

## Metrics required before optimization

The first code change adds privacy-safe debug metrics for current transport, health, reconnect count/duration, target jitter buffer, sample rates, frame duration, audio underrun/overrun counts, Bluetooth disconnect count, Wi-Fi disconnect count, and audio input stalls. Next iterations should export these to an in-app diagnostics screen and structured logs, and add packet timestamping for end-to-end/capture/encode/network/jitter metrics without recording audio content or personal data.

## Issue backlog to create or keep updated

1. Instrumentation and latency measurement.
2. Audio buffering and jitter-buffer tuning.
3. Codec/frame-size validation and Opus settings.
4. Bluetooth transport reliability and BLE fallback policy.
5. Wi-Fi disconnect/reconnect hardening.
6. Heartbeat and explicit connection state machine.
7. Foreground service/battery optimization validation across OEMs.
8. Bluetooth headset routing and headset disconnect/reconnect handling.
9. Native WebRTC media transport with STUN/TURN.
10. Local LAN encrypted media transport.
11. Transport abstraction/session manager/automatic fallback.
12. Network handover without room recreation.
13. Packet-loss/jitter impairment testing.
14. Multi-device Android test matrix and hardware limitation documentation.
