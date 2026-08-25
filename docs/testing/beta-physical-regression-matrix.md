# Tark beta physical regression matrix

This matrix is the repeatable physical acceptance record for Epic #34. CI proves software invariants; it never substitutes for the device/headset evidence below. Create one completed copy per beta candidate and record the exact Tark semantic version **and Git commit SHA** for every device.

## Run metadata

- Date/time and tester:
- Candidate commit SHA:
- App version/build label:
- Environment/location:
- RF conditions / notable interference:
- Sanitized `.tarklog` report references:

For each device record:

| Device | OS/build | Role | Transport role | Headset | VPN | Battery/background settings |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |

Never paste SSIDs, hotspot passwords, invitation secrets, raw peer ids, raw IP addresses, or unsanitized logs into this document or an issue.

## Evidence result vocabulary

Use only `PASS`, `FAIL`, `UNSUPPORTED`, or `NOT RUN`. A green CI run is not a physical `PASS`. If a case fails, attach a sanitized diagnostic summary and open a focused bug instead of changing the expected result here.

## Core matrix

| ID | Scenario | Steps | Expected outcome | Result | Evidence / issue |
| --- | --- | --- | --- | --- | --- |
| LAN-2 | Two-person shared LAN | Put two phones on the same LAN; join the same room; talk both directions for 5 min; lock/unlock both once. | Room identity stays unchanged; both riders remain mutually audible; no manual leave/rejoin. | NOT RUN | |
| HOTSPOT-2 | Two-person hotspot, screen off/on | Create local hotspot transport; join second phone; verify two-way voice; lock both phones for >=5 min; wake both. | Logical room survives; transport may recover/rebind; two-way voice returns without recreating the room. | NOT RUN | |
| HOTSPOT-3-LATE | Three-person hotspot + late join | Start with two riders; use in-room invite to add a third; talk pairwise; explicitly leave and rejoin one rider. | Third rider joins without participant-count limit; invite remains reachable; explicit leave is prompt and rejoin does not duplicate roster identity. | NOT RUN | |
| ROOM-5-SOAK | Five-person room soak | Join five devices where available; run voice/presence for 30–60 min; include screen-off periods. | No hard-coded two/three-person limit, unbounded queue growth, repeated recovery loop, or duplicate member rows. | NOT RUN | |
| HOST-LOSS | Forced hotspot-host loss | With >=3 devices connected, force the current hotspot transport to disappear; keep logical room open; follow recovery/failover UI. | Room/membership survive. Recovery is honest; no false Live before bidirectional peer evidence. If Android rotates credentials, rescan/action is clearly requested. | NOT RUN | |
| VPN-HOST | VPN enabled on hotspot host | Establish hotspot room, then enable VPN on host and exercise screen off/on/rebind. | Tark continues selecting the local Wi-Fi/hotspot path; VPN/tunnel is not chosen for room UDP traffic; voice stays bidirectional. | NOT RUN | |
| VPN-JOINER | VPN enabled on joiner | Repeat VPN test on joiner. | Selected local Wi-Fi generation wins over VPN; no one-way/sticky route after rebound. | NOT RUN | |
| MUSIC-START-STOP | Shared Music start/stop | Start two-way voice; start system-audio sharing; speak over music; stop/restart sharing twice. | Voice remains higher priority and live; media start/stop never reconnects the room; ducking returns to base gain after speech. | NOT RUN | |
| MUSIC-BLOCKED | Playback capture blocked | On a device/OEM where AudioPlaybackCapture is blocked while media is confirmed playing, start sharing. | UI reports blocked/unsupported honestly; empty media is not transmitted indefinitely; voice remains usable. | NOT RUN | |
| MUSIC-LONG | Long Shared Music playback | Play shareable synthetic/non-copyrighted audio or permitted local source for >=30 min while talking periodically. | No sustained media backlog/overflow loop; receiver health remains bounded; media degrades before voice/control. | NOT RUN | |
| BT | Bluetooth-supported path | Use Bluetooth transport within its documented room-size limits; talk, lock/unlock, reconnect headset once. | Voice remains usable within supported scope; unsupported multi-member combinations are labelled, not silently accepted. | NOT RUN | |
| GUEST | Browser guest/WebRTC path | Join through the supported guest flow and exercise voice/control according to current guest capability. | Supported guest functionality works without changing RoomId/ownership semantics; unsupported behavior is explicit. | NOT RUN | |
| ROUTE | Audio-route changes | During an active room switch between supported phone/headset routes while stationary. | Route changes recover without leaked AudioEngine owner, permanent mute, or room reconnect. | NOT RUN | |
| HELMET | Helmet/headset stationary usability | While stationary, wear the actual helmet/headset/gloves and verify core Ride Mode controls and conversation. | Primary controls are glanceable/reachable; normal wind/engine-like noise does not cause persistent music pumping. Never interact while actively riding. | NOT RUN | |
| RTL | Persian/default-language flow | Run create/join/invite/live/recovery in Persian; switch to English and repeat core screens. | RTL/layout/text remain usable, including 320 px-class width; no technical secret/address is exposed. | NOT RUN | |

## Quantitative diagnostic gates

Use the current analyzer/report output where a metric is available. Record observed values; do not invent measurements when the current log cannot prove them.

- **Reconnect/rebind:** transient recoverable network movement must not require manual room leave/rejoin. Record recovery duration from sanitized transition events.
- **One-way detection:** a peer that can receive but is not hearing our outbound path must become visible/actionable rather than remain falsely healthy.
- **Queues:** voice/media queues remain within their configured bounds; no monotonically growing backlog or memory symptom during soak.
- **Media priority:** receiver distress or backpressure degrades/suspends media before voice/control becomes materially impaired.
- **Hotspot recovery:** re-host alone is not Live when peers existed before loss; restored/bidirectional evidence is required.
- **Build provenance:** every exported report must identify the exact commit/build used for the run.

## Original failure-path minimum

Before the Epic can be physically accepted, record at least one run on a Samsung A55/A53-class Android device for the hotspot/join/recovery path that originally reproduced the problem. Where available, include a Xiaomi/MIUI/HyperOS-class device for playback-capture policy behavior. Mark unavailable hardware as `NOT RUN`; never substitute emulator/CI results.

## Acceptance summary

At the end of a candidate run, summarize separately:

- Automated/CI evidence:
- Emulator/simulator evidence (if any):
- Physical device evidence:
- Unsupported combinations:
- Open release-blocking defects:
- Open non-blocking defects:
- Final physical verdict: `PASS`, `FAIL`, or `INCOMPLETE`.

A candidate is never called physically accepted solely because CI is green.
