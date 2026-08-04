# Tark Smartwatch Companion

Branch: `feature/smartwatch-room-control`

## Product boundary

The first smartwatch release is a **room remote**, not another voice endpoint.
The phone continues to own microphone capture, headset routing, Opus, Wi-Fi /
Bluetooth transport, jitter buffering, reconnect, and the foreground keep-alive
service. The watch displays the phone's room state and sends small commands:

- mute / unmute the phone microphone;
- retry the current room connection;
- leave the room after confirmation;
- show live/connecting/reconnecting state, callsign, member count, transport,
  and the active speaker.

This boundary is deliberate: it preserves Tark's tested audio pipeline, avoids
watch microphone/headset routing conflicts, and keeps battery use low.

## Shared protocol

### Actions

Path / message type: `/tark/room/action`

- `toggle_mute`
- `reconnect`
- `leave`

### State request and response

- request: `/tark/room/state/request`
- response: `/tark/room/state/response`

The state uses the same facts already published for Tark's home-screen widget:
`session`, `callsign`, `peerCount`, `talker`, `modeLabel`, `statusLine`, and
`updatedAt`. This avoids creating a second state model that can drift from the
live room.

## Galaxy Watch6 Classic / Wear OS

The `android/wear` module is a real Wear OS APK using the same application ID
and signing certificate as the phone APK. It communicates through Google Play
services' Wearable MessageClient. The watch polls while its UI is visible, and
the phone's active Flutter engine receives controls through the existing native
widget-control channel.

Build from Android Studio or Gradle:

```bash
cd android
./gradlew :wear:assembleDebug
```

Install the handheld app on the paired Android phone and the Wear APK on the
Galaxy Watch6 Classic. Both APKs must be signed by the same certificate.

Primary test cases:

1. Open a room on the phone, then open Tark on the watch.
2. Confirm callsign, state, transport and member count update within 2 seconds.
3. Toggle mute from the watch with the phone screen off.
4. Force a transport interruption and tap reconnect.
5. Leave from the watch and verify the phone returns to Landing and releases
   the foreground service.
6. Repeat with the watch disconnected/reconnected from the phone.

## Apple Watch

The iPhone WatchConnectivity coordinator is compiled from
`ios/Runner/AppDelegate.swift`. The SwiftUI watch app source is in
`ios/TarkWatch`.

In Xcode, add **watchOS App for Existing iOS App**:

- watch app bundle ID: `com.b1101.tark.watchkitapp`;
- companion iOS bundle ID: `com.b1101.tark`;
- deployment target: watchOS 10 or newer;
- add `TarkWatchApp.swift`, `ContentView.swift`, and `WatchSessionModel.swift`
  to the watch target;
- use the supplied `Info.plist` values.

Use a physical iPhone and Apple Watch for final WatchConnectivity validation.
The simulator is useful for layout, but it does not replace paired-device tests.

## Visual system

The watch UI mirrors the current Tark room screen:

- `#090B0F` black/navy background;
- warm Tark orange `#FF7A32` and soft orange radar glow;
- charcoal rounded cards;
- green live microphone state and red destructive leave action;
- circular radar motif, sparse constellation dots, RTL Persian copy;
- bundled Vazirmatn regular and bold fonts on Wear OS;
- large controls designed for one-glance use.

## Current alpha limitations

- The watch does not capture or play room audio.
- Music-cast control is intentionally deferred until the phone exposes a safe,
  entitlement-aware command outside WalkieTalkieCubit.
- The first state payload exposes member count and active speaker, not the full
  roster. Full roster synchronization is the next protocol revision.
- The Apple Watch source is ready, but the target must be added and signed in
  Xcode because target membership and provisioning are developer-team-specific.

## Next implementation slices

1. Add full roster snapshots with bounded payload size.
2. Add haptic feedback for link loss/restoration and active speaker changes.
3. Add an optional music-cast start/stop command through a cubit-owned command
   gateway so entitlement rules remain identical to the phone UI.
4. Add Wear OS tiles and Apple Watch complications for room status only.
5. Add device tests for Galaxy Watch6 Classic and a physical Apple Watch/iPhone
   pair, including screen-off and reconnect scenarios.
