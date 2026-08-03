# Changelog

All notable changes to Tark are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.8-beta.1] — 2026-08-03

First beta test release. Everything below is present in this build; the feature
set is described in full in [README.md](README.md).

### Added

- **Real-time push-to-talk voice** — Opus at 16 kHz with a configurable (default
  100 ms) jitter buffer that self-corrects clock drift instead of letting
  playback delay grow over a long session.
- **Four transports**, all speaking the same wire format:
  - **Wi-Fi (LAN)** — UDP broadcast + unicast; the primary transport.
  - **Bluetooth** — Classic (RFCOMM) on Android, BLE GATT for iPhone and
    cross-OS. Hands-free auto-join when exactly one host is in range.
  - **Wi-Fi Hotspot Bridge** — one phone hosts a local hotspot, the other scans
    a Wi-Fi QR in the app's own scanner and joins without leaving the app.
  - **Guest (web)** — invite a browser guest over a serverless WebRTC link by QR
    or invite link; no install for the guest, and STUN lets it reach a genuinely
    remote guest.
- **VOX (voice-activated transmit)** — 700 ms hangover, 60 ms pre-roll, on by
  default so there is nothing to hold down.
- **OS voice processing** plus an app-level noise suppressor with a choice of
  engine: RNNoise (default), spectral subtraction, or both cascaded.
- **Handsfree routing** — mic and playback follow AirPods / helmet / wired
  headsets, including headsets connected mid-channel.
- **Music / device-audio cast** (Android) — forward what the phone is playing
  into the channel.
- **Auto-reconnect** across every transport, including reconnect across app
  launches for Bluetooth, surfaced as a unified health banner.
- **Role labels** — each member is announced as Base Station, Field Unit, or
  Open Air, on a backward-compatible trailing byte of the presence packet.
- **Home-screen widget** (Android + iOS) — one tap into the last-used channel
  with the mic live; Android's wide face carries working MUTE and END buttons
  that never open the app.
- **First-run onboarding** — a five-beat animated journey (language + theme,
  what the app is, callsign, transport, operator card) that ends by dropping
  straight into the join flow. Skippable, and replayable from Settings.
- **Branded splash screen**, skippable from Settings for an instant cold start.
- **Diagnostics** — a "Something wrong?" sheet on the channel screen listing the
  live state of microphone, network, connection, and peers, each with a green
  tick or a fix. Failures that retrying can clear are retried silently first;
  failures it cannot fix show the fix immediately.
- **Eyes-free audio feedback** — a distinct sound for every event that matters
  with the phone in a pocket, plus haptics on key-up. Mutable from Settings.
- **Categorized Settings** with a separate Advanced page for the technical knobs
  (VOX threshold, noise-filter strength, noise engine, jitter-buffer delay).
- **Bilingual** — Persian and English, RTL-aware, with dark and light themes and
  a circular-reveal transition when switching either.
- **Landing site** ([tarkk.ir](https://tarkk.ir)) and **guest web client**
  ([app.tarkk.ir](https://app.tarkk.ir)).

### Known limitations

- **iOS is unverified.** The iOS target is maintained without a Mac, so no build
  in this release has been run on an iOS device. RNNoise is wired for iOS but
  untested there; iOS falls back to spectral suppression if the native library
  is unavailable.
- **iOS Wi-Fi** discovers peers by unicast sweep rather than broadcast — UDP
  broadcast needs Apple's restricted multicast entitlement.
- **Bluetooth Classic is Android-only** (Apple forbids it for apps). Cross-OS
  Bluetooth runs over BLE GATT and can be flaky; the Hotspot Bridge is the
  reliable cross-OS path.
- **Hotspot hosting is Android-only** (API 26+); iOS cannot create a local
  hotspot programmatically.
- **Music cast is Android-only** (API 29+); no iOS API exposes another app's
  audio.
- Minimum OS: **Android 8.0+** / **iOS 13+**.

[1.0.8-beta.1]: https://github.com/HPTarkk/Tark/releases/tag/v1.0.8-beta.1
