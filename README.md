# Tark (تَرک) — Off-Grid Walkie-Talkie

A real-time, push-to-talk **voice walkie-talkie** that works with **no internet and no server**. Two or more phones talk to each other directly over Wi-Fi, Bluetooth, or a phone-hosted hotspot. Built for the field — e.g. two riders on motorcycles with handsfree headsets on a shared phone-hotspot link.

Cross-platform: **Android ↔ Android, iPhone ↔ iPhone, and Android ↔ iPhone.**

---

## Features

- **Real-time voice** — Opus-coded 16 kHz VOIP, transmitted and played back live with a configurable (default 60 ms) jitter buffer that self-corrects clock drift instead of letting playback delay silently grow over a long session.
- **Four transports**, all speaking the same wire format:
  - **Wi-Fi (LAN)** — UDP broadcast + unicast on the local network; primary transport.
  - **Bluetooth** — Bluetooth **Classic (RFCOMM)** on Android (highest bandwidth) and **BLE GATT** for iPhone and cross-OS. Android advertises on both at once for maximum compatibility. Both engines cap in-flight audio writes and drop the newest packet once the link falls behind (stale audio is worse than lost audio) instead of letting a slow link balloon into growing latency.
  - **Wi-Fi Hotspot Bridge** — the reliable **iPhone ↔ Android** path: Android creates a local hotspot, the iPhone joins by scanning a Wi-Fi QR, and audio then runs over Wi-Fi.
  - **Guest (web)** — invite a browser guest over a serverless WebRTC link via a QR code or a copyable invite link; no app install for the guest. Public STUN lets this reach a genuinely remote guest (not just the same LAN) — a real, legal group call over the internet, no server involved. A manual paste-code fallback covers the reply when scanning each other's screen isn't possible.
- **OS voice processing** — the platform's call-mode pipeline (echo cancellation, noise suppression, auto-gain) is engaged via `VOICE_COMMUNICATION` streams + `MODE_IN_COMMUNICATION` on Android — and, on Android, `AcousticEchoCanceler`/`NoiseSuppressor`/`AutomaticGainControl` are also attached explicitly to the capture session — and via the `.voiceChat` AVAudioSession on iOS, plus an app-level noise suppressor on top with a choice of engine: RNNoise, a recurrent-network denoiser (the production-grade choice — handles non-stationary noise like wind and traffic that classic spectral subtraction structurally can't, same family of approach WebRTC and Discord use), or classic spectral subtraction as the universal fallback. RNNoise is the default; it's wired for both Android (verified) and iOS (built, not yet tested on-device), and falls back to spectral automatically anywhere the native library isn't available (web, desktop). Switchable in Settings → Advanced.
- **Handsfree routing** — mic + playback follow AirPods / helmet / wired headsets (Bluetooth SCO engaged before the audio engine opens its streams); falls back to speakerphone.
- **VOX (voice-activated)** — no button to hold; transmits when your level crosses a threshold, with 700 ms hangover + 60 ms pre-roll so words aren't clipped.
- **Music / device-audio cast** (Android) — forward whatever is playing on the phone (music, navigation) into the channel; it plays as live audio on everyone else's device. The mix-level slider also nudges the broadcaster's own device volume to match, and stopping the cast can pause the source app too (needs one-time Notification access, since Android has no API for one app to pause another's playback directly).
- **Auto-reconnect** — a dropped link heals itself with exponential backoff (Bluetooth: host re-advertises, joiner re-dials; Wi-Fi: the UDP socket rebinds, backed by a liveness watchdog that detects a socket gone silent — not just closed — so a dead peer or a networking hiccup no longer needs a manual leave/rejoin to fix; Guest/WebRTC gets a bounded best-effort retry) — shown on-screen as a unified health banner (reconnecting spinner, or a manual "Retry now" once auto-reconnect is off or exhausted) across every transport, toggleable from Settings.
- **Eyes-free audio feedback** — a distinct sound for every event that matters while riding with the phone in a pocket: push-to-talk open/close, someone else talking, a peer joining/leaving, a link dropping or recovering, errors, and toggles, plus a light haptic tap when the channel keys up. Mutable from Settings.
- **Categorized Settings** — Profile, Voice & Audio (VOX, noise suppression, jitter-buffer delay, restore-defaults), Advanced (noise suppression engine: spectral or neural/RNNoise), Connection (transport picker, auto-reconnect, WiFi/Hotspot setup, Permissions), Sound & Alerts, Appearance, and Startup (quick access, skip splash), each its own card (reachable from Landing or a gear icon on the live channel). Opened from an active channel, voice changes apply live to that session instantly. Defaults to a hands-free voice combo — VOX wide open, noise suppression doing the work — so there's nothing to press to talk.
- **Quick access** — after the first launch, opening the app jumps straight into your last-used channel/mode instead of showing Landing again — toggleable from Settings.
- **Branded splash screen** — a short (≤3.5 s) cinematic launch sequence: an aurora backdrop, a frosted-glass emblem disc with an orbiting halo and broadcast ripples, a shimmering wordmark, and a hairline progress bar tied to the real wait — skippable from Settings for an instant cold start.
- **First-run onboarding** — a five-beat animated journey on a single continuous canvas (no page swipes): tune in (language + theme, applied live with the circular reveal), what the app is (three quick facts), pick a callsign with a live avatar preview and a shuffle die that rolls radio handles, choose a transport with plain-language guidance, and a final operator card stamped READY. Progress is a filling signal-strength meter (SIGNAL 20%→100%), and the last beat drives straight into the product — JOIN CHANNEL lands you in your transport's join flow, or a quieter link explores the lobby first. Skippable at any point, shown exactly once (existing installs never see it), and replayable from Settings → Startup.
- **Combined WiFi / Hotspot page** — one entry point with a segmented "Wi-Fi" / "Hotspot" choice instead of two separate flows; picking Wi-Fi just confirms both devices share a network, picking Hotspot walks through the existing Android-host / iPhone-join QR dance.
- **Clearer permissions** — a dedicated Permissions page (mic, Bluetooth, hotspot, background battery exemption) shows what's granted and why, instead of scattered ad hoc prompts.
- **Usage tips** — a one-time (ever), animated tips sheet with practical suggestions (ANC/handsfree headset, wearing a proper helmet, the hands-free voice defaults) surfaces a few seconds into your first session.
- **Bilingual** — Persian (فارسی) and English, RTL-aware, with a warm dark "night radio" and light "field radio" theme, and a circular-reveal transition (not a plain cross-fade) when you switch either one.

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
| Neural (RNNoise) noise suppression | ✅ default, verified | wired, unbuilt/untested on-device |

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
dart run build_runner build                                 # injectable DI
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
mic ─▶ anti-alias LPF ─▶ resample to 16 kHz ─▶ noise suppress (spectral or RNNoise) ─▶ 20 ms frames
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
│                     theme/language toggles + circular-reveal transition,
│                     permission tile), utils, sfx, and settings/ (the shared
│                     SettingsKeys/AppSettings/SettingsModel/SettingsRepository
│                     every cubit persists through)
└── feature/
    ├── audio/      — AudioEngine (mic in / speaker out via vendored audio_io),
    │                 noise suppression (spectral subtraction, or RNNoise via
    │                 the vendored FFI package in packages/rnnoise — Android
    │                 only so far), resampler, jitter buffer (drift-correcting,
    │                 sample-rate-scaled cap), device-audio capture,
    │                 voice-session bridge
    ├── transfer/   — transports + wire protocol: Wi-Fi UDP (+ liveness
    │                 watchdog), Bluetooth (Classic + BLE engines), combined
    │                 WiFi/Hotspot page, WebRTC guest (shared ice_config.dart:
    │                 STUN + gathering timeout); ConnectionHealthStatus is the
    │                 unified healthy/reconnecting/down signal every transport
    │                 emits
    ├── walkie/     — WalkieTalkieCubit + main push-to-talk console
    ├── landing/    — lobby: identity, read-only transport-mode chip, Join
    ├── onboarding/ — first-run journey: language/theme tune-in, welcome
    │                 facts, callsign (+shuffle), transport choice, stamped
    │                 operator card → straight into the join flow (one-time,
    │                 replayable from Settings)
    ├── settings/   — categorized Settings page (Profile/Voice & Audio/
    │                 Connection/Sound/Appearance/Startup) + Permissions page;
    │                 edits an active session live when opened from the
    │                 channel page
    └── splash/     — branded cold-start splash page (skippable via Settings)
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

The active transport is chosen in Settings (moved off the lobby); `TransferMode.hotspot` resolves to the Wi-Fi repository in the DI selector (the hotspot is only connection setup — the combined WiFi/Hotspot page's segmented control just picks which setup flow to show). `WalkieTalkieCubit` is an `@injectable` factory (not a GetIt singleton), so when Settings is opened from an active channel, the running cubit is threaded through go_router's `extra` param rather than looked up — Settings edits it in place for instant effect, and reads/writes through `SettingsRepository` (`lib/core/settings/`) the same way when opened standalone from Landing (no session yet).

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
