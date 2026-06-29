# WakiTaki — LAN Walkie Talkie

A real-time push-to-talk voice app for local WiFi networks. No internet or server required — devices discover each other automatically via UDP broadcast.

## Features

- **Real-time audio** — voice is transmitted and played back instantly over LAN
- **Auto-discovery** — all devices on the same subnet appear in the members list automatically
- **VOX (voice-activated)** — no button to hold; transmits when your voice exceeds a configurable threshold
- **Persistent VOX threshold** — slider value is saved and restored on next launch
- **Half-duplex gate** — local TX is suppressed for 600 ms after receiving remote audio, preventing mic/speaker echo feedback
- **Join/Leave** — tap JOIN to activate the mic; tap LEAVE CHANNEL (with confirmation) to stop transmitting
- **Editable display name** — shown to other users on the network; persisted across sessions
- **App version badge** — displayed at the bottom of both the lobby and walkie-talkie pages
- **Farsi & English** — switch language from the lobby screen; language-aware digit localization
- **Dark military-radio UI** — amber-on-navy theme with animated visualizer, staggered entrance animations, and custom page transitions

## Requirements

- Android 5.0+ or iOS 12+
- All devices must be on the **same WiFi subnet** (e.g. 192.168.1.x)
- Microphone permission must be granted at runtime

## Build

```bash
flutter pub get
flutter gen-l10n        # regenerate localizations after editing .arb files
flutter build apk --release          # Android
flutter build ios --release          # iOS (requires macOS + Xcode)
```

### Generate app icons (after first `flutter pub get`)

```bash
dart run flutter_launcher_icons
```

## How to Use

1. Open the app on two or more devices connected to the same WiFi
2. Each device shows its IP address on the lobby screen — confirm they share a subnet
3. Set your display name (optional — tap **EDIT** to change)
4. Tap **JOIN CHANNEL** to start
5. Speak into the microphone — the VOX meter shows your voice level in real time
6. Adjust the **VOX SENSITIVITY** slider if the threshold is too sensitive or not sensitive enough
7. Other devices appear in the **CHANNEL MEMBERS** list with a live TX indicator when they are talking
8. Tap **LEAVE CHANNEL** to stop transmitting; a confirmation dialog prevents accidental exits

## Technical Details

| Item | Detail |
|------|--------|
| Protocol | UDP broadcast, port 4000 |
| Packet format | `[type 1B][nameLen 4B LE][name UTF-8][payload]` |
| Packet types | `0x01` = presence, `0x02` = audio |
| Audio format | 32-bit float PCM samples |
| Discovery | Presence broadcast every 2 s; users expire after 8 s |
| Socket retry | Re-binds automatically every 3 s on failure |
| Half-duplex gate | 600 ms TX suppression window after each received audio packet |

## Architecture

```
lib/
├── core/
│   ├── di/          — Injectable + GetIt DI setup
│   ├── l10n/        — AppLocalizations (fa + en); edit .arb files, run flutter gen-l10n
│   ├── locale/      — LocaleService (runtime language switch via ValueNotifier)
│   ├── router/      — GoRouter (Landing → Walkie) with custom fade+slide+scale transition
│   └── widget/      — Shared widgets (VersionBadge)
└── feature/
    ├── audio/       — AudioVisualizer widget + RecordedAudioData entity
    ├── landing/     — Lobby page (join/leave, language toggle, staggered entrance)
    ├── walkie/      — Main walkie-talkie page + WalkieTalkieCubit (@injectable factory)
    └── transfer/    — UDP socket (TransferRepository) with generation-counter lifecycle
```

**Key design decisions:**

- `WalkieTalkieCubit` is registered as `@injectable` factory in GetIt so `WalkieTalkiePage` can resolve it without importing `AudioIo` or `TransferRepository` directly — cross-feature access only through DI.
- `TransferRepository.startListening()` uses a generation counter (`_generation`) to invalidate stale async generators on re-entry, fixing a race condition where old generators would race to rebind port 4000.
- VOX threshold and display name are persisted in `SharedPreferences` and loaded on startup.
- RTL-aware VOX meter uses explicit pixel geometry (`isRtl` boolean + `Positioned(left:)`) rather than directional widgets, because `FractionallySizedBox` alignment does not reliably invert bar growth direction under loose Stack constraints.

**Dependencies:**

- **flutter_bloc** (Cubit) for state management
- **audio_io** for microphone input and speaker output
- **go_router** for navigation
- **injectable / get_it** for dependency injection
- **shared_preferences** for local persistence
- **package_info_plus** for runtime version reading
- **Vazirmatn** font for Farsi text rendering

## Permissions (Android)

| Permission | Reason |
|---|---|
| `RECORD_AUDIO` | Microphone access |
| `INTERNET` | UDP socket binding |
| `ACCESS_NETWORK_STATE` | IP address lookup |
| `ACCESS_WIFI_STATE` | WiFi interface detection |
| `CHANGE_WIFI_MULTICAST_STATE` | Broadcast packet reception |
