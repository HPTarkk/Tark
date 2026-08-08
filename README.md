# Tark (تَرک) — Off-Grid Walkie-Talkie

A real-time, push-to-talk **voice walkie-talkie** that works with **no internet and no server**. Two or more phones talk to each other directly over Wi-Fi, Bluetooth, or a phone-hosted hotspot. Built for the field — e.g. two riders on motorcycles with handsfree headsets on a shared phone-hotspot link.

Cross-platform: **Android ↔ Android, iPhone ↔ iPhone, and Android ↔ iPhone.**

**Website: [tarkk.ir](https://tarkk.ir)** — what it does, how the link is made, and the Android download.
**Join from a browser: [app.tarkk.ir](https://app.tarkk.ir)** — the guest client, no install.

---

Copyright (c) 2026 Tarkk

This project is dual-licensed.

Open Source License:
This software is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
You may use, modify, and distribute this software under the terms of the AGPL-3.0.

Commercial License:
If you wish to use this software in a proprietary or closed-source product, or if you do not wish to comply with the AGPL-3.0, you must obtain a separate commercial license from Tarkk.

Commercial licenses are available under negotiated terms, including royalty, revenue-sharing, subscription, or one-time licensing agreements.

For commercial licensing inquiries, contact:
tarkk.hp@gmail.com

## Features

- **Real-time voice** — Opus-coded 16 kHz VOIP, transmitted and played back live with a configurable (default 100 ms) jitter buffer that self-corrects clock drift instead of letting playback delay silently grow over a long session. The buffer also keeps a small silent cushion (30 ms) queued in the native output ring: the drain timer shares an isolate with rendering, and without a head start an ordinary late tick left the audio callback with nothing to play, which it filled with zeros — a faint recurring tick on every transport. Stopping and resuming the drain is ramped rather than cut, so neither boundary steps.
- **Four transports**, all speaking the same wire format. Every packet carries a **stable per-process device id**, and the roster and the jitter buffer key on it. They used to key on whatever address the transport reported, which is not one value per device: a phone sitting on the hotspot subnet *and* another interface sends each packet from two source IPs (the limited broadcast leaves by the default route, the directed one by the AP interface), so every peer appeared **twice** in the roster and its audio was split across two jitter-buffer streams, each seeing every other sequence number and treating the gaps as loss.
  - **Wi-Fi (LAN)** — UDP broadcast + unicast on the local network; primary transport.
  - **Bluetooth** — Bluetooth **Classic (RFCOMM)** on Android (highest bandwidth) and **BLE GATT** for iPhone and cross-OS. Both ends of a classic link are **insecure RFCOMM sockets**, so two phones talk without first completing a system pairing prompt — and, just as importantly, symmetrically: a secure dial against an insecure listener has the host's `accept()` return before the client has finished authenticating, which on an unbonded pair left the host "connected" to a session the joiner had already failed out of. Android advertises on both at once for maximum compatibility. Both engines cap in-flight audio writes and drop the newest packet once the link falls behind (stale audio is worse than lost audio) instead of letting a slow link balloon into growing latency. A host also shows up **under your own name, not the phone's model number**: a classic inquiry only ever reports the remote adapter name, so hosting temporarily renames the adapter (restored on stop, on exit, and on the next launch after a kill) and tags it so a joiner can tell Tark hosts apart from the headsets and TVs in the same scan — untagged devices are **filtered out of the list entirely**, so the joiner sees people rather than hardware (BLE peers are filtered on the service UUID instead, and a remembered host being re-dialed is let through regardless, since Android can still be reporting its stale cached adapter name). When exactly one host is in range the join happens **hands-free after a two-second settle**, with a Cancel always on screen.
  - **Wi-Fi Hotspot Bridge** — the reliable path when there's no shared network, cross-OS or Android-to-Android: one phone creates a local hotspot and shows a Wi-Fi QR, the other scans it **in the app's own scanner** — a framed viewfinder wearing the same amber brackets and scanline as the code it's reading, with a torch toggle, tap-to-focus, and a haptic green lock on the hit — and joins **without ever leaving the app**: Android through a `WifiNetworkSpecifier` request (a single system dialog), iOS through `NEHotspotConfiguration`. The joining side is then pinned to that network with `bindProcessToNetwork`, which is what keeps the session alive: a local-only hotspot has no internet, so left alone Android moves the default network back to cellular a few seconds in and the app's UDP quietly stops reaching the peer while every socket still looks healthy.
  - **Guest (web)** — invite a browser guest over a serverless WebRTC link via a QR code or a copyable invite link; no app install for the guest. Public STUN lets this reach a genuinely remote guest (not just the same LAN) — a real, legal group call over the internet, no server involved. A manual paste-code fallback covers the reply when scanning each other's screen isn't possible.
- **Everyone's part in the link, named** — each member's tile in the channel (and your own card at the top) carries a second line saying what that device is: **Base Station** for whoever is holding the link up (the Bluetooth host, the phone running the hotspot, the app hosting a browser guest), **Field Unit** for whoever came in over it, **Open Air** when nobody hosts and everyone simply met on the same network. Every device *announces its own part* in its presence packets rather than having it inferred at the far end, because the far end frequently can't: on a hotspot with three phones, a joiner sees the other two on the subnet with nothing to say which of them brought the AP up. The role rides along as a trailing byte on the existing presence message with no new packet type — a build from before this reads exactly what it always did and simply never says what it is, so it goes unlabelled rather than mislabelled, and audio packets (which carry no role) never overwrite what a peer last announced.
- **OS voice processing** — the platform's call-mode pipeline (echo cancellation, noise suppression, auto-gain) is engaged via `VOICE_COMMUNICATION` streams + `MODE_IN_COMMUNICATION` on Android — and, on Android, `AcousticEchoCanceler`/`NoiseSuppressor`/`AutomaticGainControl` are also attached explicitly to the capture session — and via the `.voiceChat` AVAudioSession on iOS, plus an app-level noise suppressor on top with a choice of engine: RNNoise, a recurrent-network denoiser (the production-grade choice — handles non-stationary noise like wind and traffic that classic spectral subtraction structurally can't, same family of approach WebRTC and Discord use), classic spectral subtraction as the universal fallback, or both cascaded (RNNoise first, spectral mopping up residual steady hum) for the quietest result at the highest battery cost. RNNoise is the default; it's wired for both Android (verified) and iOS (built, not yet tested on-device), and falls back to spectral automatically anywhere the native library isn't available (web, desktop). Switchable in Settings → Advanced settings, presented as a plain-words three-way choice (simple / smart / both together) with each option's trade-off spelled out.
- **Handsfree routing** — mic + playback follow AirPods / helmet / wired headsets (Bluetooth SCO engaged before the audio engine opens its streams); falls back to speakerphone. The headset is always preferred, whether it was already on when you joined **or connected mid-channel**: the OS reports the device appearing or disappearing, and the engine re-picks the route and re-opens its streams (Android has to release the pinned communication device first, or a session that started on speaker would stay on speaker). Unplugging mid-channel drops back to speakerphone the same way.
- **VOX (voice-activated)** — no button to hold; transmits when your level crosses a threshold, with 700 ms hangover + 60 ms pre-roll so words aren't clipped.
- **Music / device-audio cast** (Android) — forward whatever is playing on the phone (music, navigation) into the channel; it plays as live audio on everyone else's device. The mix-level slider also nudges the broadcaster's own device volume to match, and stopping the cast can pause the source app too (needs one-time Notification access, since Android has no API for one app to pause another's playback directly).
- **Auto-reconnect** — a dropped link heals itself with exponential backoff (Bluetooth: host re-advertises, joiner re-dials; Wi-Fi: the UDP socket rebinds, backed by a liveness watchdog that detects a socket gone silent — not just closed — so a dead peer or a networking hiccup no longer needs a manual leave/rejoin to fix; Guest/WebRTC gets a bounded best-effort retry) — shown on-screen as a unified health banner (reconnecting spinner, or a manual "Retry now" once auto-reconnect is off or exhausted) across every transport, toggleable from Settings. The same toggle also covers **reconnect across launches** for Bluetooth: after the first explicitly-confirmed session, reopening the Bluetooth screen resumes the *same role* hands-free — the device that hosted re-hosts, the device that joined keeps re-dialing the remembered host until it answers, so the two reconnect no matter which app launches first. Runs only when nothing would prompt (permissions already granted, adapter already on), with a Cancel escape back to the manual host/join choice. The resumed host still confirms Android's discoverable window when it isn't already open — listening on RFCOMM alone makes a device *connectable*, not *findable*, so skipping it left a joiner that scanned (rather than re-dialing a remembered address) staring at an empty list. If that timed window later lapses while the host is still waiting, the beacon says so and offers a one-tap re-arm instead of silently going invisible. Both sides also put one presence packet on the wire the instant a link forms, which is what lets a host tell a real session from a *phantom* one — an RFCOMM socket it accepted but the joiner never registered (the joiner keeps dialing while the host thinks it is connected, and with the 1-to-1 server socket closed after that first accept, nothing can get in). Silence past a grace period drops the phantom and re-listens rather than stranding the pair.
- **Nothing fails silently, and nothing is a dead end** — the failures that hurt most in a walkie-talkie are the ones that look like success: the channel is up, everyone else comes through perfectly, and not a word you say leaves the phone. Three of those were previously invisible — a microphone permission that was refused, a capture device that reported itself started and then delivered nothing (the engine's watchdog restarting it every two seconds behind a screen that still read **MIC LIVE**), and an IP transport with no local address, where the transmit gate silently refuses to send. All three now say so in plain words with the fix attached, and a channel that failed to open mid-setup is a retry button rather than a screen stuck on "connecting" forever with only Leave to press. Failures that clear on their own are never shown at all: hotspot hosting and a tapped Bluetooth peer get **up to four automatic attempts** first, staying on their ordinary "connecting" screen for the first two and softening to "still trying…" after that, so a radio hiccup that resolves on attempt two never looked like a problem — while a failure retrying *cannot* fix (tethering already on, location off, permission refused) skips the attempts entirely and shows the fix immediately, because spending ten seconds not telling someone the one thing they need to hear is worse than a bare error. Backing all of it is a **"Something wrong?"** sheet on the channel screen, always one tap away, listing the live state of every dependency — microphone, network, connection, who's in range — with a green tick or a fix beside each. The healthy rows matter as much as the broken ones: *microphone: working, network: connected* is what tells you the problem is at the other end.
- **Eyes-free audio feedback** — a distinct sound for every event that matters while riding with the phone in a pocket: push-to-talk open/close, someone else talking, a peer joining/leaving, a link dropping or recovering, errors, and toggles, plus a light haptic tap when the channel keys up. Mutable from Settings.
- **Categorized Settings** — Profile, Connection (transport picker, auto-reconnect, WiFi/Hotspot setup, Permissions), Sound & Alerts, Appearance, and Startup (skip splash, replay intro), each its own card (reachable from Landing or a gear icon on the live channel). Technical knobs live on a separate **Advanced settings** sub-page: Voice & Audio (VOX threshold, noise-filter strength, restore-defaults), the noise-cleaner engine as a jargon-free three-way choice (simple / smart / both together, each with its trade-off spelled out), and the jitter-buffer playback delay. Opened from an active channel, voice changes apply live to that session instantly. Defaults to a hands-free voice combo — VOX wide open, noise suppression doing the work — so there's nothing to press to talk.
- **Home-screen widget** (Android + iOS) — a radio-dial console on the home screen: one tap drops you straight into your last-used channel with the mic already live (VOX is open by default, so arriving *is* going on air), and the face itself reports the session — ON AIR, who's talking, muted, reconnecting, or how many people are on the channel — as a lit rim whose ticks track the roster, a bloom that swells with activity, a gauge that swings with the state, and a level strip under the status line that genuinely animates on Android — a widget can't run code, but `ViewFlipper` is a RemoteViews-supported class that cycles its own children, so cross-fading three phase-shifted level frames reads as a meter that's actually moving (off a live session all three frames render identically, so it sits still). iOS has no equivalent: WidgetKit renders static snapshots, so there the strip is still. Both platforms set their type in Vazirmatn — the app's own family, shipped as Android font resources and bundled into the iOS extension — since the platform default would otherwise render the widget in a different typeface from every screen it launches into, and has no Persian weights. It follows the app's own language *and* theme rather than the system's (both are in-app settings, and the two routinely disagree), so display strings are published pre-localized from the ARB files instead of being duplicated into `strings.xml`. On **Android** the wide size also carries working **MUTE and END buttons that never open the app**: while a session is live the process is already held up by the keep-alive foreground service, so the tap is forwarded straight into the running Dart isolate. iOS has no equivalent — an extension can't reach a backgrounded app — so it deep-links instead. Discoverability rides on the existing one-time usage-tips sheet — a fourth tip, with its own looping animation (`core/widget/animations/widget_loop_animation.dart`), rather than a prompt of its own: that sheet is already an earned moment a few seconds into a first session, so the widget gets found without anything new interrupting. Settings → Startup then carries **Add the channel widget**, which where the launcher supports pinning (Android 8+, most launchers) hands it over in one tap instead of making anyone hunt through the widget picker; the row hides itself where that can't work (iOS has no such API), since instructions that vary per launcher and OS version would be worse than nothing. A session killed by the OS (rather than ended cleanly) can never leave a permanent "LIVE" on the home screen: state carries a publish timestamp and is demoted once stale, and on iOS the timeline is scheduled to refresh at exactly that moment.
- **Branded splash screen** — a short (≤3.5 s) cinematic launch sequence: an aurora backdrop, a frosted-glass emblem disc with an orbiting halo and broadcast ripples, a shimmering wordmark, and a hairline progress bar tied to the real wait — skippable from Settings for an instant cold start.
- **First-run onboarding** — a five-beat animated journey on a single continuous canvas (no page swipes): tune in (language + theme, applied live with the circular reveal), what the app is (three quick facts), pick a callsign with a live avatar preview and a shuffle die that rolls radio handles, choose a transport with plain-language guidance, and a final operator card stamped READY. Beats hand over in stages: the old panel winds up and is thrown off the end of the screen, the stage sits deliberately empty for a moment while parallax wind tears through it, and the next panel is brought in from the start under a targeting reticle that snaps onto its corners. Progress is a filling signal-strength meter (SIGNAL 20%→100%), and the last beat drives straight into the product — JOIN CHANNEL lands you in your transport's join flow, or a quieter link explores the lobby first. Skippable at any point, shown exactly once (existing installs never see it), and replayable from Settings → Startup.
- **Combined WiFi / Hotspot page** — one entry point with a segmented "Wi-Fi" / "Hotspot" choice instead of two separate flows. Plain Wi-Fi bypasses the page entirely — Join drops straight into the channel, since there's nothing to set up — so it only appears for the explicit Hotspot flow or when opened deliberately from Settings → Connection. In Wi-Fi mode, Landing shows a compact **Hotspot** shortcut beside JOIN CHANNEL for one-tap access to the hotspot flow without switching mode first. Picking Hotspot asks which end this phone is — **create** or **join** — rather than assuming (Android used to be hard-wired as the host, which left two Androids with no in-app way to pair, and meant a phone that couldn't host greeted you with a failure you never asked for). Nothing touches the radio until you commit to a side, and when hosting genuinely can't work the error says *which* thing to fix, offers to open that settings screen, and offers to join the other phone instead. The host screen is just the code — Tarkk's mark stamped in its centre — for the first ten seconds; only once a scan has visibly gone nowhere does a line fade in offering the network name and password. Credentials on screen invite people to type what the camera was about to do for them, so they stay off it while the fast path is still live.
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
| Wi-Fi Hotspot Bridge — **join** | ✅ (in-app `WifiNetworkSpecifier`, API 29+; legacy `addNetwork` below that) | ✅ (auto-join needs the *Hotspot Configuration* capability, else manual) |
| Music / device-audio cast | ✅ (API 29+) | ❌ (no OS API to capture other apps' audio) |
| OS echo-cancel / noise-suppress / AGC | ✅ (`VOICE_COMMUNICATION`) | ✅ (`.voiceChat`) |
| Neural (RNNoise) noise suppression | ✅ default, verified | wired, unbuilt/untested on-device |
| Home-screen widget | ✅ (resizable; compact + wide faces) | ✅ (WidgetKit, small + medium; needs iOS 14+) |
| Widget MUTE / END without opening the app | ✅ | ❌ (an extension can't reach a backgrounded app) |

Minimum OS: **Android 8.0+** (hotspot host needs 8.0, music cast needs 10.0) / **iOS 13+**.

---

## Which transport should I use?

- **Same Wi-Fi network already?** Use **Wi-Fi**.
- **Two Androids, no network?** Use **Bluetooth** (Classic — best range/quality) or Hotspot — either phone can be the host, and the other scans its code in the app.
- **iPhone + Android, no network?** Use the **Hotspot Bridge** (most reliable). Bluetooth LE cross-OS also works but can be flaky (iOS hides its advertisement when backgrounded; some Android chipsets can't advertise) — the Bluetooth screen offers a one-tap jump to the Hotspot Bridge.
- **Talk to someone with no app — anywhere, not just the same room?** Use **Guest** and send them the QR or the invite link (works over the internet via STUN; a few strict/corporate networks may still block it).

> **Scanning the host's code lands on "join this network yourself"?** Two system switches on the *scanning* phone can cause it, and the join screen now names whichever one it is instead of dropping you at the manual card. **Wi-Fi off** — `WifiNetworkSpecifier` needs the radio, and Android rejects the request instantly rather than prompting; the screen offers the toggle inline (a system panel from Android 10, as far as an app is allowed to reach). **Location off** — through Android 12 that stops Wi-Fi *scanning*, so the system's network picker comes up empty and cancels itself ~30s later; same requirement the hotspot host has always preflighted. Worth knowing if you host on the same phone: some builds leave Wi-Fi off after a local-only hotspot is torn down.

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
- **App Groups** capability is present, containing `group.com.b1101.tark`, on **both** the *Runner* and *TarkWidgetExtension* targets. The App Group is the only channel through which the home-screen widget can read app state; if the group is missing (or the two targets disagree), the widget builds and installs fine but reads an empty store and shows its "finish setup" placeholder forever. Both `.entitlements` files already declare it — automatic signing registers the group on first build, otherwise click **+ Capability → App Groups** on each target.
- `Info.plist` already declares the usage strings (`NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`) and `UIBackgroundModes` (`audio`, `bluetooth-central`, `bluetooth-peripheral`).

> iOS Wi-Fi note: UDP broadcast is blocked without Apple's restricted `com.apple.developer.networking.multicast` entitlement, so on iOS the app discovers peers by unicast sweep + Local Network permission instead.

### Guest web app

The browser-guest experience is a separate web entrypoint:

```bash
flutter build web --release -t lib/main_guest.dart
# deploy build/web to any static HTTPS host; set the URL via
#   --dart-define GUEST_APP_URL=https://your-host  (see lib/core/config/guest_config.dart)
```

The deployed instance is [app.tarkk.ir](https://app.tarkk.ir), which is what `GUEST_APP_URL` defaults to.

### Landing site

`website/` is the static marketing site served at [tarkk.ir](https://tarkk.ir) — plain HTML, CSS and JS, deployed as-is. `robots.txt`, `sitemap.xml` and the canonical and hreflang URLs in both pages name that origin, so they need updating together if the site ever moves.

It ships in two languages, one URL each: English at `/` and Persian at `/fa/`. Search engines need each language served as its own document with its own title, description and structured data, so `website/fa/index.html` is **generated** from `website/index.html` — every translatable element carries a `data-fa` attribute, and the build swaps them in along with the head metadata and the Persian FAQ structured data.

```sh
node scripts/build-website-i18n.mjs           # regenerate website/fa/index.html
node scripts/build-website-i18n.mjs --check    # verify it is current; exits 1 if not
```

Edit `website/index.html` and rebuild — never edit `website/fa/index.html` by hand. Persian text lives in the `data-fa` attributes; the Persian `<title>`, meta description and social copy live in the `FA` block at the top of the script. `--check` also verifies the English FAQ structured data still quotes the FAQ section verbatim, since a rich result must not show text the page does not contain.

---

## Audio pipeline

```
mic ─▶ anti-alias LPF ─▶ resample to 16 kHz ─▶ noise suppress (spectral, RNNoise, or both cascaded) ─▶ 20 ms frames
     ─▶ VOX gate (hangover + pre-roll) ─▶ [+ mixed device audio] ─▶ Opus encode ─▶ transport
transport ─▶ Opus decode (per-sender) ─▶ jitter buffer (~100 ms) ─▶ resample to device rate ─▶ speaker
```

- **Codec:** Opus 16 kHz mono VOIP (`opus_dart` + `opus_flutter`), packet type `0x03`. PCM16 (`0x02`) is a fallback and stays decodable for back-compat.
- **OS voice session:** engaged before the engine opens its streams (`tark/audio_session` channel → `AudioSessionHandler` on each platform). This gives call-grade echo cancellation / noise suppression / AGC where the device supports it. On Android the vendored `audio_io` allocates an AAudio session id (miniaudio patch) so the three effects are attached explicitly, not just implied by the input preset.
- **Full duplex:** TX and RX run independently like a phone call. On loudspeaker (not headphones) some residual echo can occur on devices with weak OS AEC — headphones eliminate it.
- **Realtime boundary:** mic and speaker samples cross between miniaudio's realtime callback and the Dart isolate through a lock-free single-producer/single-consumer ring buffer (`packages/audio_io/src/double_ring_buffer.h`). The callback never locks or allocates — a mutex shared with the isolate is a priority-inversion trap, and either one costs a missed deadline, i.e. an audible dropout.

---

## Wire protocol

Transport-agnostic (identical bytes over UDP, RFCOMM, and BLE). All multi-byte integers little-endian.

| Field | Bytes | Notes |
|---|---|---|
| type | 1 | `0x01` presence · `0x02` PCM16 audio · `0x03` Opus audio |
| name length | 4 | uint32 |
| name | *n* | UTF-8 display name |
| presence payload | 1 + 1 + *k* | `isTalking` (0/1) · session role · heard-peer list |
| audio payload | 4 + *m* | seq (uint32) + Opus packet (or PCM16 samples) |

The presence payload grows by appending, never by changing what came before, so a
build that predates a field simply stops reading and is unaffected. The **heard-peer
list** (count byte, then length-prefixed device ids) is how a phone finds out its own
transmissions are going nowhere: every other signal it has is about receiving, and a
device whose send path has died still has a bound socket, a healthy link and a full
roster. Absent means "no opinion" (older build, or a point-to-point transport);
present but empty is a statement — "I can hear nobody".

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
│                     permission tile), utils, sfx, settings/ (the shared
│                     SettingsKeys/AppSettings/SettingsModel/SettingsRepository
│                     every cubit persists through), and home_widget/ (the
│                     home-screen widget bridge: the key contract shared with
│                     native, snapshot publishing, and launch-tap parsing)
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
    │                 replayable from Settings). Beats change via
    │                 packages/beat_transitions; the horizon scene caches its
    │                 ridge paths, stars and shaders so the 60fps layer stays
    │                 affordable on older phones
    ├── settings/   — categorized Settings page (Profile/Voice & Audio/
    │                 Connection/Sound/Appearance/Startup) + Permissions page;
    │                 edits an active session live when opened from the
    │                 channel page
    └── splash/     — branded cold-start splash page (skippable via Settings)
packages/
├── audio_io/       — vendored, one Android patch: streams open as
│                     VOICE_COMMUNICATION class so call-mode routing applies
├── rnnoise/        — FFI binding to RNNoise, vendored + built per platform
└── beat_transitions/ — app-agnostic step transitions for the onboarding
                      journey (HandoverTransition + the older SignalSweep),
                      with no palette/cubit/router coupling so they are
                      reusable
android/…/kotlin/com/b1101/tark/
├── audio/          — AudioSessionHandler (call routing/SCO), SystemAudioCapture,
│                     MediaControlHandler + TarkNotificationListenerService
│                     (pause other apps' media on stop-cast)
├── bluetooth/      — BluetoothServerHandler (insecure RFCOMM host *and* dial, bounded write queue)
├── hotspot/        — HotspotHandler (LocalOnlyHotspot host)
│                     WifiJoinHandler (WifiNetworkSpecifier join + process binding)
└── widget/         — home-screen widget: TarkWidgetProvider (RemoteViews),
                      DialRenderer (the Canvas-drawn dial), and
                      TarkWidgetControlReceiver + WidgetControlBridge, which
                      carry MUTE/END into the running engine without
                      foregrounding the app
ios/Runner/         — AudioSessionHandler + HotspotJoinHandler (Swift)
ios/TarkWidget/     — WidgetKit extension (SwiftUI): TarkWidget.swift draws the
                      same dial, SharedState.swift reads the App Group store
```

The active transport is chosen in Settings (moved off the lobby); `TransferMode.hotspot` resolves to the Wi-Fi repository in the DI selector (the hotspot is only connection setup — the combined WiFi/Hotspot page's segmented control just picks which setup flow to show). `WalkieTalkieCubit` is an `@injectable` factory (not a GetIt singleton), so when Settings is opened from an active channel, the running cubit is threaded through go_router's `extra` param rather than looked up — Settings edits it in place for instant effect, and reads/writes through `SettingsRepository` (`lib/core/settings/`) the same way when opened standalone from Landing (no session yet).

Cold start decides where to land before `runApp()`: `main.dart` calls `QuickAccess.resolveStartLocation` (same pattern as the existing `TransferModeStore.initialize()` preload) to compute `AppRouter.startLocation` — onboarding on a true first run, Landing otherwise. It used to skip Landing and drop returning users straight into their last-used transport; the home-screen widget replaced that, offering the same one-tap route into a channel but only when asked for, rather than taking the decision away from every launch. A widget tap is resolved in the same place and outranks the splash screen, since it names a destination explicitly. Widget taps carry a nonce that is consumed once: the platform never clears the launch intent and `MainActivity` is `singleTop`, so without it every later engine start would replay the last tap — and that tap lands on an open mic.

Anything the widget *renders* — its strings are localized and its colors themed at publish time — has to be pushed to it when those settings change, since no session event fires: `MyApp` calls `HomeWidgetService.refresh()` from the same listener that rebuilds the tree on a language or theme switch.

---

## Android permissions

| Permission | Reason |
|---|---|
| `RECORD_AUDIO` | Microphone |
| `MODIFY_AUDIO_SETTINGS` | Call-mode + Bluetooth SCO routing |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | Wi-Fi sockets & broadcast |
| `CHANGE_WIFI_STATE`, `NEARBY_WIFI_DEVICES` | Hotspot Bridge (LocalOnlyHotspot) |
| `CHANGE_NETWORK_STATE` | Joining the host's hotspot in-app (`requestNetwork` + process binding) |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` (≤ API 32) | Required by BT scan / LocalOnlyHotspot on older APIs. Both run to 32 on purpose: from Android 12 a fine-location request is ignored unless coarse is requested in the same call, so capping coarse lower makes the hotspot permission ungrantable |
| `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE` | Bluetooth Classic + BLE (host & join) |
| `BLUETOOTH`, `BLUETOOTH_ADMIN` (≤ API 30) | Legacy Bluetooth |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` | Device-audio (music) cast |
| Notification access (optional, granted via system settings — not a manifest permission) | Lets stopping music-cast also pause the source app's playback |

---

## Privacy & analytics

Conversations never leave the local link. Audio goes phone-to-phone over Wi-Fi,
Bluetooth or the hosted hotspot, and there is no server in the path — that part
of the pitch is literal, and nothing below changes it.

The app does collect anonymous usage statistics, so that connection failures
we can't reproduce still get fixed. It's a plain **on/off switch in Settings →
Privacy**, on by default.

What's sent, when it's on:

- Which transport a pairing attempt used, and whether it connected or failed —
  with a failure reason from a fixed list (`perm_denied`, `discover_timeout`,
  `ap_never_up`, …)
- Bucketed session shape: roughly how long, roughly how many people, roughly
  how many transmissions (`2_10m`, `4_5`, `10_plus` — never exact values)
- Which optional features were used at least once in a session

What is never sent: callsigns, peer names, device names, SSIDs, IP or MAC
addresses, contacts, location, and no audio of any kind, ever. Every attribute
is a value from a closed enum defined in
[`lib/core/analytics/analytics_event.dart`](lib/core/analytics/analytics_event.dart)
— there is no free-text field to leak into.

The backend is [AdTrace](https://adtrace.io), chosen because it's the one
option that's both free and reachable from Iranian networks (Firebase and
Sentry are sanction-blocked at the endpoint). Its SDK merges an advertising-ID
permission and Facebook/Instagram `<queries>` probes into the manifest by
default; all three are stripped at merge time — see the comment at the top of
[`AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml).

Building without analytics at all, no code changes needed:

```bash
flutter build apk --release --dart-define=ADTRACE_TOKEN=
```

---

## Diagnostics

The bugs worth chasing here only exist on someone else's phone: a hotspot link
that goes one-way after the screen locks, an AP the OS tore down, a mic that
opened and delivered nothing. `adb logcat` reaches none of that, so the app keeps
its own log.

**For users.** Settings → Advanced → Diagnostics → *Share diagnostic log*. It writes a
`.tarklog` file and hands it to the share sheet. The log stays on the phone until
you send it, and *Clear the log* deletes it.

**What's in it.** Session lifecycle, screen on/off transitions, socket bind and
rebind events, per-peer send failures, and a line every 15 s summarising the whole
transport — packets in and out, known peers, local addresses, broadcast targets,
socket state. No audio, ever.

**How big it gets.** Exactly as big as you allow and no bigger. The same
Diagnostics section carries a *Max log size* slider — 20 KB to 100 MB, 8 MB by
default — with a meter showing how much of it is currently spent. On disk the log
is a chain of numbered segments; when the next line would take it past the
ceiling, the oldest segment is deleted. It never grows without bound, and lowering
the ceiling reclaims the space straight away rather than at some later write. See
[`log_budget.dart`](lib/core/diagnostics/log_budget.dart) for the range and
[`diagnostic_log.dart`](lib/core/diagnostics/diagnostic_log.dart) for the rotation.

**Reading one.** The file is gzip plus a keystream — opaque in a chat thread, and
awkward to "tidy up" before sending, which is how the one line that mattered goes
missing. It is **not encrypted**: the key is a constant in a shipped app. Decode it
with:

```bash
python3 scripts/decode_tark_log.py tark-log-20260807-181500.tarklog
```

The container is defined in
[`tark_log_format.dart`](lib/core/diagnostics/tark_log_format.dart); the script and
that file have to move together, and a cross-language golden vector in
[`test/tark_log_format_test.dart`](test/tark_log_format_test.dart) fails if they
drift apart.

---

## Support the project

Every feature is unlocked — Bluetooth, Wi-Fi, hotspot, music cast, all of it.
Nothing in the app asks you for money.

Development still costs something, though: test devices to reproduce the radio
bugs that only show up on one specific phone, a domain, and the hosting behind
[app.tarkk.ir](https://app.tarkk.ir). If Tark is useful to you and you'd like
to help with that:

**[reymit.ir/tark](https://reymit.ir/tark)**

Any amount is genuinely useful, and not donating changes nothing about what
you get. Reporting a bug with enough detail to reproduce it is worth just as
much — see [ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE).

---

## License

See [LICENSE](LICENSE).
