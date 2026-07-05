# Tark (تَرک) — Off-Grid Walkie-Talkie

A real-time, push-to-talk **voice walkie-talkie** that works with **no internet and no server**. Two or more phones talk to each other directly over Wi-Fi, Bluetooth, or a phone-hosted hotspot. Built for the field — e.g. two riders on motorcycles with handsfree headsets on a shared phone-hotspot link.

Cross-platform: **Android ↔ Android, iPhone ↔ iPhone, and Android ↔ iPhone.**

---

## Features

- **Real-time voice** — Opus-coded 16 kHz VOIP, transmitted and played back live with sub-100 ms jitter buffering.
- **Four transports**, all speaking the same wire format:
  - **Wi-Fi (LAN)** — UDP broadcast + unicast on the local network; primary transport.
  - **Bluetooth** — Bluetooth **Classic (RFCOMM)** on Android (highest bandwidth) and **BLE GATT** for iPhone and cross-OS. Android advertises on both at once for maximum compatibility.
  - **Wi-Fi Hotspot Bridge** — the reliable **iPhone ↔ Android** path: Android creates a local hotspot, the iPhone joins by scanning a Wi-Fi QR, and audio then runs over Wi-Fi.
  - **Guest (web)** — invite a browser guest over a serverless WebRTC LAN link via two QR codes; no app install for the guest.
- **OS voice processing** — the platform's call-mode pipeline (echo cancellation, noise suppression, auto-gain) is engaged via `VOICE_COMMUNICATION` streams + `MODE_IN_COMMUNICATION` on Android and the `.voiceChat` AVAudioSession on iOS, plus an app-level spectral noise suppressor on top.
- **Handsfree routing** — mic + playback follow AirPods / helmet / wired headsets (Bluetooth SCO engaged before the audio engine opens its streams); falls back to speakerphone.
- **VOX (voice-activated)** — no button to hold; transmits when your level crosses a threshold, with 700 ms hangover + 60 ms pre-roll so words aren't clipped.
- **Music / device-audio cast** (Android) — forward whatever is playing on the phone (music, navigation) into the channel; it plays as live audio on everyone else's device.
- **Auto-reconnect** — a dropped Bluetooth session heals itself (host re-advertises, joiner re-dials with backoff).
- **Bilingual** — Persian (فارسی) and English, RTL-aware, with a warm dark "night radio" and light "field radio" theme.

---

## Platform support

| Feature | Android | iOS |
|---|---|---|
| Wi-Fi (LAN) voice | ✅ | ✅ (unicast; broadcast is blocked without Apple's multicast entitlement) |
| Bluetooth Classic (RFCOMM) | ✅ | ❌ (Apple forbids Classic for apps) |
| Bluetooth LE (GATT) | ✅ | ✅ |
| Wi-Fi Hotspot Bridge — **host** | ✅ (API 26+) | ❌ (iOS can't create a local hotspot programmatically) |
| Wi-Fi Hotspot Bridge — **join** | ✅ | ✅ (auto-join needs the *Hotspot Configuration* capability, else manual) |
| Music / device-audio cast | ✅ (API 29+) | ❌ (no OS API to capture other apps' audio) |
| OS echo-cancel / noise-suppress / AGC | ✅ (`VOICE_COMMUNICATION`) | ✅ (`.voiceChat`) |

Minimum OS: **Android 8.0+** (hotspot host needs 8.0, music cast needs 10.0) / **iOS 13+**.

---

## Which transport should I use?

- **Same Wi-Fi network already?** Use **Wi-Fi**.
- **Two Androids, no network?** Use **Bluetooth** (Classic — best range/quality) or Hotspot.
- **iPhone + Android, no network?** Use the **Hotspot Bridge** (most reliable). Bluetooth LE cross-OS also works but can be flaky (iOS hides its advertisement when backgrounded; some Android chipsets can't advertise) — the Bluetooth screen offers a one-tap jump to the Hotspot Bridge.
- **Talk to someone with no app?** Use **Guest** and send them the QR.

---

## Setup & build

```bash
flutter pub get

# Code generation (required after changing DI annotations or ARB files)
dart run build_runner build --delete-conflicting-outputs   # injectable DI
flutter gen-l10n                                            # localizations
dart run flutter_launcher_icons                             # app icons (first run)

flutter build apk --release        # Android
flutter build ios --release        # iOS (requires macOS + Xcode)
```

### iOS-specific requirements

After pulling native changes, in `ios/`:

```bash
pod install
```

Then open `ios/Runner.xcworkspace` in Xcode and confirm, under **Signing & Capabilities** for the *Runner* target:

- **Hotspot Configuration** capability is present (it drives `Runner.entitlements` / `NEHotspotConfiguration` for iOS auto-join). With automatic signing Xcode adds it from the entitlement automatically; if not, click **+ Capability → Hotspot Configuration**. Without it, iOS falls back to a manual "join this Wi-Fi in Settings" flow.
- `Info.plist` already declares the usage strings (`NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`) and `UIBackgroundModes` (`audio`, `bluetooth-central`, `bluetooth-peripheral`).

> iOS Wi-Fi note: UDP broadcast is blocked without Apple's restricted `com.apple.developer.networking.multicast` entitlement, so on iOS the app discovers peers by unicast sweep + Local Network permission instead.

### Guest web app

The browser-guest experience is a separate web entrypoint:

```bash
flutter build web --release -t lib/main_guest.dart
# deploy build/web to any static HTTPS host; set the URL via
#   --dart-define GUEST_APP_URL=https://your-host  (see lib/core/config/guest_config.dart)
```

---

## Audio pipeline

```
mic ─▶ anti-alias LPF ─▶ resample to 16 kHz ─▶ spectral noise suppress ─▶ 20 ms frames
     ─▶ VOX gate (hangover + pre-roll) ─▶ [+ mixed device audio] ─▶ Opus encode ─▶ transport
transport ─▶ Opus decode (per-sender) ─▶ jitter buffer (~100 ms) ─▶ resample to device rate ─▶ speaker
```

- **Codec:** Opus 16 kHz mono VOIP (`opus_dart` + `opus_flutter`), packet type `0x03`. PCM16 (`0x02`) is a fallback and stays decodable for back-compat.
- **OS voice session:** engaged before the engine opens its streams (`tark/audio_session` channel → `AudioSessionHandler` on each platform). This is what gives call-grade echo cancellation / noise suppression / AGC where the device supports it.
- **Full duplex:** TX and RX run independently like a phone call. On loudspeaker (not headphones) some residual echo can occur on devices with weak OS AEC — headphones eliminate it.

---

## Wire protocol

Transport-agnostic (identical bytes over UDP, RFCOMM, and BLE). All multi-byte integers little-endian.

| Field | Bytes | Notes |
|---|---|---|
| type | 1 | `0x01` presence · `0x02` PCM16 audio · `0x03` Opus audio |
| name length | 4 | uint32 |
| name | *n* | UTF-8 display name |
| presence payload | 1 | `isTalking` (0/1) |
| audio payload | 4 + *m* | seq (uint32) + Opus packet (or PCM16 samples) |

| Item | Detail |
|---|---|
| Wi-Fi port | UDP 4000 (directed broadcast on every private /24 + limited broadcast + unicast to known peers) |
| Discovery | presence every 2 s; users expire after 8 s |
| Bluetooth | Classic SPP UUID `00001101-…`; BLE service `C0DE0001-57A1-4B1E-9A0B-2D6577616B69` |
| BLE framing | length-prefixed + chunked to the negotiated ATT MTU |

---

## Architecture

Clean architecture + BLoC (Cubit), `injectable`/`get_it` DI, `go_router`. Each feature has `api/` + `domain/` + `data/` + `presentation/`; cross-feature access is **only** through a feature's `api/` barrel. `lib/app/` is the composition root (router + DI); `lib/core/` is the shared kernel. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full breakdown.

```
lib/
├── app/            — composition root: DI wiring (di_config.dart) + GoRouter
├── core/           — theme, l10n (fa/en), router, shared widgets, utils
└── feature/
    ├── audio/      — AudioEngine (mic in / speaker out via vendored audio_io),
    │                 spectral noise suppressor, resampler, jitter buffer,
    │                 device-audio capture, voice-session bridge
    ├── transfer/   — transports + wire protocol: Wi-Fi UDP, Bluetooth
    │                 (Classic + BLE engines), Hotspot Bridge, WebRTC guest
    ├── walkie/     — WalkieTalkieCubit + main push-to-talk console
    └── landing/    — lobby: identity, transport picker (2×2), theme/lang
packages/
└── audio_io/       — vendored, one Android patch: streams open as
                      VOICE_COMMUNICATION class so call-mode routing applies
android/…/kotlin/com/b1101/tark/
├── audio/          — AudioSessionHandler (call routing/SCO), SystemAudioCapture
├── bluetooth/      — BluetoothServerHandler (RFCOMM host)
└── hotspot/        — HotspotHandler (LocalOnlyHotspot)
ios/Runner/         — AudioSessionHandler + HotspotJoinHandler (Swift)
```

The active transport is chosen on the lobby; `TransferMode.hotspot` resolves to the Wi-Fi repository in the DI selector (the hotspot is only connection setup). `WalkieTalkieCubit` is an `@injectable` factory so it resolves whichever transport singleton is active.

---

## Android permissions

| Permission | Reason |
|---|---|
| `RECORD_AUDIO` | Microphone |
| `MODIFY_AUDIO_SETTINGS` | Call-mode + Bluetooth SCO routing |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | Wi-Fi sockets & broadcast |
| `CHANGE_WIFI_STATE`, `NEARBY_WIFI_DEVICES` | Hotspot Bridge (LocalOnlyHotspot) |
| `ACCESS_FINE_LOCATION` (≤ API 32) | Required by BT scan / LocalOnlyHotspot on older APIs |
| `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` | Bluetooth Classic + BLE (host & join) |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` (≤ API 30) | Legacy Bluetooth |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` | Device-audio (music) cast |

---

## License

See [LICENSE](LICENSE).
