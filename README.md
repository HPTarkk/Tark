# Tark (تَرک) — Off-Grid Walkie-Talkie

Real-time, push-to-talk voice between two or more phones — **no internet, no server, no account.** Wi-Fi, Bluetooth, or a phone-hosted hotspot carry the audio directly, phone to phone. Built for the field: two riders on motorcycles, handsfree headsets, a shared hotspot link, and nothing else around.

**Android ↔ Android, iPhone ↔ iPhone, Android ↔ iPhone.**

**Website: [tarkk.ir](https://tarkk.ir)** · **Join from a browser, no install: [app.tarkk.ir](https://app.tarkk.ir)**

---

Copyright (c) 2026 Tarkk — dual-licensed.

**Open source:** AGPL-3.0. Use, modify, distribute freely under its terms.
**Commercial:** want it in a closed-source product, or don't want AGPL's terms? Email **tarkk.hp@gmail.com** for a negotiated license (royalty, revenue-share, subscription, or one-time).

## Features

- **Real-time voice** — Opus at 16 kHz with in-band FEC (a lost packet is rebuilt from the next one, not left as a hole), tuned from the *far end's* loss reports rather than a local guess. An adaptive jitter buffer (60–180 ms) tracks the link instead of sitting at a fixed delay, self-corrects clock drift, and ramps its own start/stop instead of clicking.
- **Four transports, one wire format.** Every packet carries a stable per-device id, so the roster and jitter buffer never mistake one phone's two network interfaces for two different peers.
  - **Wi-Fi (LAN)** — UDP broadcast + unicast on a shared network. The default, and the fastest to set up.
  - **Bluetooth** — Classic RFCOMM on Android (best range/quality), BLE GATT for iPhone and cross-OS. No pairing prompt required. Auto-joins hands-free when exactly one host is in range.
  - **Wi-Fi Hotspot Bridge** — the reliable cross-OS path with no shared network: one phone hosts, the other scans the QR in the app's own scanner (torch, tap-to-focus, haptic lock) and joins without leaving the app.
  - **Guest (web)** — invite a browser over a serverless WebRTC link (QR or copyable invite), no install. Public STUN means this reaches a genuinely remote guest, not just the same room.
- **Everyone's role, labeled** — each member's tile says what they *are*: Base Station (whoever's holding the link up), Field Unit (whoever joined through it), or Open Air (nobody's hosting). Self-announced by each device, so it's never guessed wrong.
- **OS-grade voice processing** — platform echo cancellation / noise suppression / AGC (`VOICE_COMMUNICATION` on Android, `.voiceChat` on iOS), plus an app-level cleaner: RNNoise (neural, default, Android verified / iOS built but untested), classic spectral subtraction as the universal fallback, or both cascaded. Switchable in Advanced settings.
- **Handsfree routing** — mic and playback follow AirPods, a helmet headset, or wired audio, whether connected before or during a call. Falls back to speakerphone.
- **VOX (voice-activated)** — no button to hold. Transmits when your voice clears the background by a *margin* you set (not an absolute level), so one setting works parked and at highway speed. 700 ms hangover and 60 ms pre-roll keep words from clipping. 0% is truly off — nothing is ever held back.
- **A host stays on its own hotspot** — if a phone is hosting *and* still connected to some other Wi-Fi, it only looks for peers on the hotspot it's actually running, not every network it can see.
- **"Turn Wi-Fi off" — before the drop, not after.** Some Android chipsets can't run a hotspot and a Wi-Fi client at once; if a remembered network comes back in range mid-ride, Android can silently kill the hotspot. The host screen says so *while the QR is still up*, with a one-tap system panel — the app can't flip the toggle itself (no API since Android 10), so it just asks well.
- **Riding mode** — one switch for "phone in a jacket pocket, behind a helmet." Arms the VOX floor, runs the neural cleaner at a moderate strength, deepens the jitter buffer, and lifts playback through a limiter that can't clip. It overrides your other settings without touching them — turn it off and everything reverts exactly as you left it.
- **Music / device-audio cast** (Android) — share whatever's playing on your phone into the channel as live audio, with its own volume slider and a one-tap "pause the source app" on stop.
- **Rides out of Wi-Fi range without dropping** — set a room up on the house Wi-Fi and leave, and the connection used to die at the end of the street: the network the group was borrowing simply stopped existing, and by then there was no path left to agree on a replacement. The app now moves off a borrowed network *before* you go. A few seconds after everyone's in, one phone quietly becomes the hub and hands its details to the others over the link that still works — while you're stationary, in range, with time in hand. Nobody scans anything, nobody is asked about networking, and the only thing said out loud is on the hub phone: it's off the internet until the room closes. A network the group owns (a hotspot, or Bluetooth) is left alone; so is a borrowed one when nobody present can host, because a network that works beats no network at all. Every handover is signed by a room member, so nothing on the café Wi-Fi can steer your group onto its own access point.
- **Auto-reconnect** — a dropped link heals itself (exponential backoff, socket liveness watchdog, cross-launch Bluetooth role resumption) with a unified health banner and manual "Retry now." No leave-and-rejoin needed for a hiccup.
- **Nothing fails silently** — a refused mic permission, a mic that's "started" but delivering nothing, a dead send path — all three used to look like a working session. Now they say so, with the fix attached, and a **"Something wrong?"** sheet is always one tap away showing every dependency's live state.
- **Pre-ride Preflight** — before you're on air, a quick check answers "ready to ride?": real mic frames actually arriving (not just permission granted), which route you'll be heard through (helmet vs. phone speaker), local network/transport health, and background-execution posture (battery optimization, notification permission) — each with a one-tap fix, never a dead end. Warnings never block; only a genuine hard failure (denied mic, no usable network) does.
- **Eyes-free audio feedback** — a distinct sound for push-to-talk keying up, someone else talking, a peer joining/leaving, a link dropping/recovering, and errors, plus a light haptic tap when you key up. Mutable from Settings.
- **Categorized Settings** — Profile, Riding mode, Connection, Sound & Alerts, Appearance, Startup, each its own card, plus an Advanced page for the technical knobs (transport pin, VOX threshold, noise-filter engine, jitter-buffer delay). Edits an active session live.
- **Home-screen widget** (Android + iOS) — one tap into your last channel, mic already live. The face itself shows session state — on air, who's talking, muted, reconnecting — as an animated dial. Android's wide widget also has working MUTE/END buttons that never open the app.
- **Branded splash & first-run onboarding** — a short cinematic launch and a five-beat animated intro (language/theme, what the app is, pick a callsign, how phones link up, ready). Both skippable, onboarding shown once.
- **Start or join, transport chosen for you** — the main screen asks one question you're actually the authority on (*starting, or arriving?*) and works out Wi-Fi vs. hotspot vs. Bluetooth from what your phone can see. Pin one by hand in Advanced settings if you'd rather.
- **Channel codes** — six characters, readable aloud through a helmet, so two groups on the same café Wi-Fi don't land in one conversation. Rides inside the existing hotspot QR, so it costs nothing extra to scan.
- **Combined Wi-Fi / Hotspot page** — one entry point, a segmented Wi-Fi/Hotspot choice, and Hotspot asks which side you are instead of assuming.
- **Clear permissions, one-time tips, bilingual** — a dedicated permissions page, a one-time practical-tips sheet, and full Persian (فارسی, RTL) + English support with a proper day/night theme.

---

## Platform support

| Feature | Android | iOS |
|---|---|---|
| Wi-Fi (LAN) voice | ✅ | ✅ (unicast; broadcast needs Apple's multicast entitlement) |
| Bluetooth Classic (RFCOMM) | ✅ | ❌ (Apple forbids Classic for apps) |
| Bluetooth LE (GATT) | ✅ | ✅ |
| Wi-Fi Hotspot Bridge — **host** | ✅ (API 26+) | ❌ (no programmatic hotspot API) |
| Wi-Fi Hotspot Bridge — **join** | ✅ (in-app, API 29+) | ✅ (auto-join needs *Hotspot Configuration*, else manual) |
| Music / device-audio cast | ✅ (API 29+) | ❌ (no OS capture API) |
| OS echo-cancel / noise-suppress / AGC | ✅ | ✅ |
| Neural (RNNoise) noise suppression | ✅ default, verified | wired, unbuilt/untested on-device |
| Home-screen widget | ✅ (compact + wide) | ✅ (WidgetKit, iOS 14+) |
| Widget MUTE/END without opening the app | ✅ | ❌ (extensions can't reach a backgrounded app) |

Minimum OS: **Android 8.0+** (hotspot host needs 8.0, music cast needs 10.0) / **iOS 13+**.

---

## Which transport should I use?

**You don't have to pick.** The main screen asks one thing — starting a channel, or joining one? — and resolves the rest from what your phone can see. Each button names the route before it takes it. Pin one by hand in Settings → Advanced settings if you'd rather skip the ladder.

- **Same Wi-Fi already?** → **Wi-Fi** — and if you then ride away from it, the app moves the group onto a hotspot of its own before the Wi-Fi disappears, without asking you anything.
- **Two Androids, no network?** → **Bluetooth** (best range/quality) or the **Hotspot Bridge**.
- **iPhone + Android, no network?** → **Hotspot Bridge** (most reliable). Bluetooth LE also works but can be flaky cross-OS.
- **Someone with no app, anywhere?** → **Guest** — send the QR or link. Works over the real internet via STUN; a few strict corporate networks may block it.

> **Scanning a host's code drops you into "join this Wi-Fi yourself"?** Usually **Wi-Fi is off** on your phone (the join screen now offers the toggle inline) or **Location is off** (needed for Wi-Fi scanning through Android 12).

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

Then in `ios/Runner.xcworkspace`, under **Signing & Capabilities** for the *Runner* target, confirm:

- **Hotspot Configuration** is present (drives `NEHotspotConfiguration` for auto-join). Automatic signing usually adds it; otherwise **+ Capability → Hotspot Configuration**. Without it, iOS falls back to a manual "join this Wi-Fi in Settings" flow.
- **App Groups** contains `group.com.b1101.tark` on **both** *Runner* and *TarkWidgetExtension*. This is the only channel the home-screen widget has into app state — miss it (or let the two targets disagree) and the widget shows its "finish setup" placeholder forever.
- `Info.plist` already declares the usage strings and `UIBackgroundModes` (`audio`, `bluetooth-central`, `bluetooth-peripheral`).

> iOS Wi-Fi note: UDP broadcast needs Apple's restricted multicast entitlement, which this app doesn't have — iOS discovers peers by unicast sweep + Local Network permission instead.

### Guest web app

A separate web entrypoint:

```bash
flutter build web --release -t lib/main_guest.dart
# deploy build/web to any static HTTPS host; set the URL via
#   --dart-define GUEST_APP_URL=https://your-host  (see lib/core/config/guest_config.dart)
```

Deployed at [app.tarkk.ir](https://app.tarkk.ir), which is `GUEST_APP_URL`'s default.

### Landing site

`website/` is the static marketing site at [tarkk.ir](https://tarkk.ir) — plain HTML/CSS/JS, deployed as-is, in two languages (English at `/`, Persian at `/fa/`).

**Edit `website/index.html` only** — `website/fa/index.html` is generated from it (every translatable element carries a `data-fa` attribute; Persian `<title>`/meta/social copy live in the `FA` block at the top of the build script).

```sh
node scripts/build-website-i18n.mjs           # regenerate website/fa/index.html
node scripts/build-website-i18n.mjs --check    # verify it's current; exits 1 if not
```

---

## Audio pipeline

```
mic ─▶ anti-alias LPF ─▶ resample to wire rate ─▶ noise suppress (spectral, RNNoise, or both) ─▶ 20 ms frames
     ─▶ VOX gate (adaptive floor, hangover + pre-roll) ─▶ [+ mixed device audio] ─▶ Opus encode (in-band FEC) ─▶ transport
transport ─▶ Opus decode (per-sender, FEC recovery) ─▶ jitter buffer (adaptive 60–180 ms) ─▶ resample to device rate ─▶ speaker
```

- **Codec** — Opus mono VOIP via direct `libopus` bindings (`opus_dart` + `opus_flutter`), with a same-quality `opus_dart`-only fallback and a PCM16 fallback below that, so there's always a working codec.
- **In-band FEC** — each packet carries a low-bitrate copy of the previous frame, so one lost packet is rebuilt from the next instead of leaving a hole. How much redundancy to spend is decided from **the far end's** measured loss (reported once a second), never guessed locally.
- **Adaptive jitter buffer** — depth tracks the link instead of sitting at a fixed delay: it grows the instant the queue runs dry (a shallow buffer is heard immediately as chopped speech) and only gives depth back after ten clean seconds.
- **VOX as a margin** — the slider is *how far above the background* your voice must rise, not an absolute level, so the same setting works in a quiet room and at highway speed. Off (0%) truly means nothing is ever held back.
- **Bounded noise cleaning** — the goal is intelligibility, not silence. Nothing the app chooses *for* you (the default, Riding mode) runs a cleaner flat out, since over-cleaning eats exactly the consonants a lossy link is already chewing.
- **Full duplex** — TX and RX run independently, like a phone call.
- **Realtime-safe** — mic/speaker samples cross the native↔Dart boundary through a lock-free ring buffer; the realtime audio callback never locks or allocates.

**Negotiated 24 kHz HD voice.** Two capable phones automatically negotiate up to 24 kHz instead of the older fixed 16 kHz, falling back to 16 kHz for any peer that doesn't support it — on by default, no version mismatch, ever. Validated on two real Android devices end to end (negotiation, jitter buffer, and reliability all held across screen-off stretches) before becoming the default for everyone. Toggleable per phone in Settings > Advanced (HD Voice), alongside the same on-by-default negotiation for HD Shared Music (48 kHz stereo).

---

## Wire protocol

Transport-agnostic (identical bytes over UDP, RFCOMM, and BLE). All multi-byte integers little-endian. Shown here is the current (widest) shape; older, shorter variants are still decoded for backward compatibility — a build that predates a field simply stops reading it.

| Field | Bytes | Notes |
|---|---|---|
| type | 1 | one byte per message-kind × version, e.g. presence / PCM16 audio / Opus audio |
| device id | 1 + *n* | length-prefixed, stable per process |
| session epoch | 4 | tells a rejoin apart from a stale packet still in flight |
| channel id | 4 | only present once a channel is named |
| name | 4 + *n* | length-prefixed UTF-8 display name |
| presence payload | 1 + 1 + *k* + 1 | `isTalking` · session role · heard-peer list · audio capability bitmask |
| audio payload | 4 + *m* | seq (uint32) + Opus packet (or PCM16 samples) |

Every field beyond the header was added by *appending*, never by changing what came before — a build that predates a field just stops reading and is unaffected. The **heard-peer list** is how a phone learns its own transmissions are going nowhere (every other signal it has is about *receiving*). The **capability bitmask** is what the in-development HD-voice negotiation above rides on.

| Item | Detail |
|---|---|
| Wi-Fi port | UDP 4000 (broadcast + unicast to known peers) |
| Discovery | presence every 2 s; peers expire after 8 s |
| Bluetooth | Classic SPP UUID `00001101-…`; BLE service `C0DE0001-57A1-4B1E-9A0B-2D6577616B69` |
| BLE framing | length-prefixed + chunked to the negotiated ATT MTU |

---

## Architecture

Clean architecture + BLoC (Cubit), `injectable`/`get_it` DI, `go_router`. Each feature is `api/` + `domain/` + `data/` + `presentation/`; cross-feature access only ever goes through a feature's `api/` barrel. `lib/app/` is the composition root; `lib/core/` is the shared kernel. Full breakdown in [ARCHITECTURE.md](ARCHITECTURE.md).

```
lib/
├── app/            — composition root: DI wiring, GoRouter, cold-start routing
├── core/           — theme, l10n (fa/en), shared widgets, settings, sfx,
│                     home-widget bridge, and core/audio/ (the shared
│                     wire-format contract both audio and transfer key off)
└── feature/
    ├── audio/      — AudioEngine (mic/speaker via vendored audio_io), noise
    │                 suppression, resampler, jitter buffer, device-audio capture
    ├── transfer/   — transports + wire protocol: Wi-Fi UDP, Bluetooth
    │                 (Classic + BLE), combined WiFi/Hotspot page, WebRTC guest
    ├── walkie/     — WalkieTalkieCubit + main push-to-talk console
    ├── landing/    — lobby: identity, transport-mode chip, and the way in
    │                 (resume · join · new room · all rooms)
    ├── onboarding/ — first-run journey (one-time, replayable from Settings)
    ├── settings/   — categorized Settings + Permissions pages
    └── splash/     — branded cold-start splash (skippable)
packages/
├── audio_io/       — vendored native audio I/O, patched for call-mode routing
├── rnnoise/        — FFI binding to RNNoise, vendored + built per platform
└── beat_transitions/ — app-agnostic step transitions for onboarding
android/…/kotlin/com/b1101/tark/ — audio session/BT/hotspot handlers, widget provider
ios/Runner/, ios/TarkWidget/      — Swift equivalents + WidgetKit extension
```

---

## Android permissions

| Permission | Reason |
|---|---|
| `RECORD_AUDIO` | Microphone |
| `MODIFY_AUDIO_SETTINGS` | Call-mode + Bluetooth SCO routing |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | Wi-Fi sockets & broadcast |
| `CHANGE_WIFI_STATE`, `NEARBY_WIFI_DEVICES` | Hotspot Bridge |
| `CHANGE_NETWORK_STATE` | Joining a hotspot in-app |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` (≤ API 32) | Required by BT scan / hotspot on older APIs |
| `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` | Bluetooth Classic + BLE |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` (≤ API 30) | Legacy Bluetooth |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` | Device-audio (music) cast |
| Notification access (optional, granted via system settings) | Lets stopping music-cast also pause the source app |

---

## Privacy & analytics

Conversations never leave the local link — phone to phone over Wi-Fi, Bluetooth, or a hosted hotspot, no server in the path. That's literal, and nothing below changes it.

Anonymous usage stats are **off by default**, toggled in Settings → Privacy, and exist purely so connection failures we can't reproduce still get fixed. When on, what's sent: which transport a pairing attempt used and whether it connected; a bucketed session shape (never exact numbers); which optional features got used. What's never sent: callsigns, peer names, device names, SSIDs, IP/MAC addresses, contacts, location, or any audio — every attribute is a value from a closed enum in [`analytics_event.dart`](lib/core/analytics/analytics_event.dart), so there's no free-text field to leak into.

Backend is [AdTrace](https://adtrace.io) — the one option that's free and reachable from Iranian networks. Its SDK's advertising-ID permission and Facebook/Instagram `<queries>` probes are stripped at merge time.

Build without analytics entirely:

```bash
flutter build apk --release --dart-define=ADTRACE_TOKEN=
```

---

## Diagnostics

The bugs worth chasing here only happen on someone else's phone, mid-ride. `adb logcat` reaches none of that, so the app keeps its own rotating log.

**For users:** Settings → Advanced → Diagnostics → *Share diagnostic log* hands a `.tarklog` file to the share sheet. It stays on the phone until you send it; *Clear the log* deletes it. A *Max log size* slider (20 KB–100 MB, 8 MB default) caps it — the oldest segment is dropped, never the whole thing.

**What's in it:** session lifecycle, screen on/off, socket events, per-peer send failures, a transport summary line every 15 s. No audio, ever.

**Reading one:** it's gzip plus a keystream — opaque in a chat thread, not encrypted (the key ships in the app). Decode with:

```bash
python3 scripts/decode_tark_log.py tark-log-20260807-181500.tarklog
```

Format defined in [`tark_log_format.dart`](lib/core/diagnostics/tark_log_format.dart); a cross-language golden test keeps the script and that file honest with each other.

---

## Support the project

Every feature is unlocked — Bluetooth, Wi-Fi, hotspot, music cast, all of it. Nothing in the app asks you for money.

Development still costs something: test devices for radio bugs that only show up on one specific phone, a domain, hosting for [app.tarkk.ir](https://app.tarkk.ir). If Tark's useful to you:

**[reymit.ir/tark](https://reymit.ir/tark)**

Any amount helps, and not donating changes nothing about what you get. A well-reproduced bug report is worth just as much — see [ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE).

---

## License

See [LICENSE](LICENSE).
