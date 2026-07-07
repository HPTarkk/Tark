# Tark (تَرک) — Off-Grid Walkie-Talkie

A real-time, push-to-talk **voice walkie-talkie** that works with **no internet and no server**. Two or more phones talk to each other directly over Wi-Fi, Bluetooth, or a phone-hosted hotspot. Built for the field — e.g. two riders on motorcycles with handsfree headsets on a shared phone-hotspot link.

Cross-platform: **Android ↔ Android, iPhone ↔ iPhone, and Android ↔ iPhone.**

---

## Features

- **Real-time voice** — Opus-coded 16 kHz VOIP, transmitted and played back live with sub-100 ms jitter buffering.
- **Four transports**, all speaking the same wire format:
  - **Wi-Fi (LAN)** — UDP broadcast + unicast on the local network; primary transport.
  - **Bluetooth** — Bluetooth **Classic (RFCOMM)** on Android (highest bandwidth) and **BLE GATT** for iPhone and cross-OS. Android advertises on both at once for maximum compatibility. Both engines cap in-flight audio writes and drop the newest packet once the link falls behind (stale audio is worse than lost audio) instead of letting a slow link balloon into growing latency.
  - **Wi-Fi Hotspot Bridge** — the reliable **iPhone ↔ Android** path: Android creates a local hotspot, the iPhone joins by scanning a Wi-Fi QR, and audio then runs over Wi-Fi.
  - **Guest (web)** — invite a browser guest over a serverless WebRTC link via a QR code or a copyable invite link; no app install for the guest. Public STUN lets this reach a genuinely remote guest (not just the same LAN) — a real, legal group call over the internet, no server involved. A manual paste-code fallback covers the reply when scanning each other's screen isn't possible.
- **OS voice processing** — the platform's call-mode pipeline (echo cancellation, noise suppression, auto-gain) is engaged via `VOICE_COMMUNICATION` streams + `MODE_IN_COMMUNICATION` on Android — and, on Android, `AcousticEchoCanceler`/`NoiseSuppressor`/`AutomaticGainControl` are also attached explicitly to the capture session — and via the `.voiceChat` AVAudioSession on iOS, plus an app-level spectral noise suppressor on top.
- **Handsfree routing** — mic + playback follow AirPods / helmet / wired headsets (Bluetooth SCO engaged before the audio engine opens its streams); falls back to speakerphone.
- **VOX (voice-activated)** — no button to hold; transmits when your level crosses a threshold, with 700 ms hangover + 60 ms pre-roll so words aren't clipped.
- **Music / device-audio cast** (Android) — forward whatever is playing on the phone (music, navigation) into the channel; it plays as live audio on everyone else's device. The mix-level slider also nudges the broadcaster's own device volume to match, and stopping the cast can pause the source app too (needs one-time Notification access, since Android has no API for one app to pause another's playback directly).
- **Auto-reconnect** — a dropped link heals itself with exponential backoff (Bluetooth: host re-advertises, joiner re-dials; Wi-Fi: the UDP socket rebinds) — shown on-screen as a "reconnecting" banner across every transport.
- **Eyes-free audio feedback** — a distinct sound for every event that matters while riding with the phone in a pocket: push-to-talk open/close, someone else talking, a peer joining/leaving, a link dropping or recovering, errors, and toggles, plus a light haptic tap when the channel keys up. Mutable from Settings.
- **Consolidated Settings** — name, VOX threshold, noise suppression, sound cues, theme, and language all live in one Settings page (reachable from Landing or a gear icon on the live channel) instead of scattered across screens. Opened from an active channel, changes apply live to that session instantly.
- **Quick access** — after the first launch, opening the app jumps straight into your last-used channel/mode instead of showing Landing again — toggleable from Settings.
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
- **Talk to someone with no app — anywhere, not just the same room?** Use **Guest** and send them the QR or the invite link (works over the internet via STUN; a few strict/corporate networks may still block it).

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
- **OS voice session:** engaged before the engine opens its streams (`tark/audio_session` channel → `AudioSessionHandler` on each platform). This gives call-grade echo cancellation / noise suppression / AGC where the device supports it. On Android the vendored `audio_io` allocates an AAudio session id (miniaudio patch) so the three effects are attached explicitly, not just implied by the input preset.
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
├── app/            — composition root: DI wiring (di_config.dart) + GoRouter,
│                     quick_access.dart (cold-start routing decision)
├── core/           — theme, l10n (fa/en), router, shared widgets (incl.
│                     theme/language toggles, section header), utils, sfx
└── feature/
    ├── audio/      — AudioEngine (mic in / speaker out via vendored audio_io),
    │                 spectral noise suppressor, resampler, jitter buffer,
    │                 device-audio capture, voice-session bridge
    ├── transfer/   — transports + wire protocol: Wi-Fi UDP, Bluetooth
    │                 (Classic + BLE engines), Hotspot Bridge, WebRTC guest
    │                 (shared ice_config.dart: STUN + gathering timeout)
    ├── walkie/     — WalkieTalkieCubit + main push-to-talk console
    ├── landing/    — lobby: identity, transport picker (2×2), Join
    └── settings/   — consolidated Settings page: identity, VOX/noise, sound
                      cues, appearance, quick-access toggle; edits an active
                      session live when opened from the channel page
packages/
└── audio_io/       — vendored, one Android patch: streams open as
                      VOICE_COMMUNICATION class so call-mode routing applies
android/…/kotlin/com/b1101/tark/
├── audio/          — AudioSessionHandler (call routing/SCO), SystemAudioCapture,
│                     MediaControlHandler + TarkNotificationListenerService
│                     (pause other apps' media on stop-cast)
├── bluetooth/      — BluetoothServerHandler (RFCOMM host, bounded write queue)
└── hotspot/        — HotspotHandler (LocalOnlyHotspot)
ios/Runner/         — AudioSessionHandler + HotspotJoinHandler (Swift)
```

The active transport is chosen on the lobby; `TransferMode.hotspot` resolves to the Wi-Fi repository in the DI selector (the hotspot is only connection setup). `WalkieTalkieCubit` is an `@injectable` factory (not a GetIt singleton), so when Settings is opened from an active channel, the running cubit is threaded through go_router's `extra` param rather than looked up — Settings edits it in place for instant effect, and reads/writes `SharedPreferences` directly the same way when opened standalone from Landing (no session yet).

Cold start decides where to land before `runApp()`: `main.dart` calls `QuickAccess.resolveStartLocation` (same pattern as the existing `TransferModeStore.initialize()` preload) to compute `AppRouter.startLocation`, so returning users skip Landing entirely.

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
| Notification access (optional, granted via system settings — not a manifest permission) | Lets stopping music-cast also pause the source app's playback |

---

## License

See [LICENSE](LICENSE).
