# Tark Reliability Roadmap

Hardening plan derived from Hamidreza's field-test review. The goal for the next
release is not features:

> **Connect two phones, put them in your pockets, ride for an hour, and never
> have to pull the phone out to touch the app.**

This file is the cross-session checkpoint. Each phase lists what already exists
in the codebase (verified, with file references) and what is genuinely missing,
so a later session can pick up without re-deriving the audit.

**No rewrite.** Every item below is incremental hardening on top of the existing
architecture.

---

## Status at a glance

| Phase | Focus | State |
| --- | --- | --- |
| **P0** | Core reliability | **Done** — all four |
| **P1** | Audio quality | Not started |
| **P2** | Connection UX | Not started |
| **P3** | Polish & diagnostics | Link quality indicator done |
| **CI** | Re-enable pipeline | **Parked** — deliberately deferred |

---

## Audit: what the review asked for that is already done

The review was written against `main` a few days ago and several of its P0 items
had already landed. Verified present, **do not rebuild**:

| Review item | Where it lives | Notes |
| --- | --- | --- |
| Device identity independent of IP | [device_identity.dart](lib/core/identity/device_identity.dart) | 12-hex per-process id, on the wire since packet v2 |
| One device arriving on two routes | [sender_route_pin.dart](lib/feature/transfer/domain/service/sender_route_pin.dart) | Per-sender route pin with a 6 s grace + repin |
| Host + Join exclusivity | [session_role_store.dart](lib/feature/transfer/domain/service/session_role_store.dart) | Commit `7649dca` |
| Peer vanishing kills both directions | `_recoveryPeers` in [wifi_transfer_repository_impl.dart](lib/feature/transfer/data/repository/wifi_transfer_repository_impl.dart) | Aged-out peers stay unicast targets for 2 min |
| **TX/RX health separation** | `heardIds` on [waki_packet.dart](lib/feature/transfer/domain/entity/waki_packet.dart), graded in [walkie_talkie_cubit.dart](lib/feature/walkie/presentation/manager/walkie_talkie_cubit.dart) | `unheardByPeers` — "they hear me" is a distinct signal from "I hear them". Certifies the presence path only; the unicast ping in P0 §4 covers the audio path |
| Liveness watchdog | `_livenessTimer` in the Wi-Fi repo | Rebinds a socket that is bound but silent |
| Duplicate audio seq drop | [audio_playback_buffer.dart](lib/feature/audio/data/audio_playback_buffer.dart) | Plus reorder + gap concealment |

So P0 is **narrower than the review implies** — most of it shipped. What remains
is below.

---

## P0 — Core reliability *(current)*

### 1. Session ID  — the real gap

Nothing on the wire identifies *which session* a packet belongs to. The v2
header is `type | idLen | deviceId | nameLen | name | body`
([waki_packet_codec.dart](lib/feature/transfer/data/codec/waki_packet_codec.dart)).

Without it, a packet from a previous session is indistinguishable from a live
one, because `senderId` is stable for the life of the *process*, not the
session. A phone that leaves and rejoins — or whose peer restarts its
hotspot — can have in-flight datagrams from the old session accepted by the new
one, feeding a stale `seq` into the jitter buffer and triggering a resync flush
the user hears as repeated or broken speech.

Matters most during: Wi-Fi reconnects, hotspot restarts, app resume, network
handoff, Bluetooth reconnect.

**Done**, as a per-sender *session epoch* rather than a shared room id:

- [x] [`SessionEpoch`](lib/core/identity/session_epoch.dart) — a counter
      renewed on each join
- [x] Wire v3 (`0x07/0x08/0x09`) carries it after the device id; v1 and v2 are
      still decoded, so a newer build still hears an older one
- [x] [`SessionEpochGate`](lib/feature/transfer/domain/service/session_epoch_gate.dart)
      drops a packet from a sender's previous join; a rejoin (higher epoch)
      takes over with no grace period
- [x] Enforced in the Wi-Fi receive path *before* the peer map, heard list and
      route pin, so a ghost cannot refresh any of them. A rejoin clears that
      sender's route pin and Opus decoder state
- [x] `staleEpoch=` / `epoch=` on the session log line
- [x] Tests: [session_epoch_gate_test.dart](test/session_epoch_gate_test.dart),
      plus epoch + v2-compat cases in
      [waki_packet_codec_test.dart](test/waki_packet_codec_test.dart)

**Why an epoch and not the review's shared `TARK-A83F21` session id.** Every
case the review lists — Wi-Fi reconnect, hotspot restart, app resume, network
handoff, Bluetooth reconnect — is one device's *own* previous join leaking into
its next one. That needs a value comparable within a single sender, which a
counter does with `<`, needing no clock, no agreement between devices and no
distribution channel. A shared room id answers a different question ("are we in
the same room as those other people"), needs the QR/credential plumbing that is
itself P2 work, and would have blocked this behind it. The two compose: a room
id can be added in P2 without revisiting any of the above.

Not done, deferred with the rest of the QR work:

- [ ] Shared room id in the QR / hotspot credentials, to keep two adjacent
      channels on one Wi-Fi apart (P2)

### 2. Reconnect state machine

Today `ConnectionHealth` has three states — `healthy` / `reconnecting` / `down`
([connection_health.dart](lib/feature/transfer/domain/entity/connection_health.dart)).
The review asks for a graded ladder:

```
CONNECTED → DEGRADED → RECOVERING → RENEGOTIATING → DISCONNECTED
```

**Done.**

- [x] `degraded` and `renegotiating` added to
      [connection_health.dart](lib/feature/transfer/domain/entity/connection_health.dart),
      ordered as a ladder
- [x] [`RecoveryLadder`](lib/feature/transfer/domain/service/recovery_ladder.dart) —
      attempt 1 is **quiet** (`degraded`), 2–3 are visible (`reconnecting`),
      4+ escalate to `renegotiating`, which discards the network assumptions
      (peer-narrowed broadcast, resolved targets, sweep) before the next bind
- [x] `ConnectionHealth.isLive` — the banner and the link-lost **sound** now key
      on this, so a dip repaired on the first retry is never announced.
      `isHealthy` stays strict for the transport's own logic
- [x] The troubleshooting sheet deliberately does *not* stay quiet — it reports
      degraded as amber, because the user opened it to ask
- [x] Tests: [recovery_ladder_test.dart](test/recovery_ladder_test.dart)

**The behaviour change that matters:** at the opening backoff delay the quiet
rung is ~4 s, so the 2–3 second dips a phone takes constantly at speed no
longer light the banner or play the link-lost sound. Previously every one of
them did, which is how riders learn to ignore both.

### 3. TX/RX health separation — already existed

Verified during the audit, no work needed. `heardIds` +
`unheardByPeers` already answer "can anybody hear me?" as a signal
independent of "can I hear them?" — see the table above.

### 4. Independent heartbeat — **done, unicast-only**

The review proposed a `PING/PONG` carrying
`session, sender, route, lastRxSequence, lastTxSequence, audioRxPackets`.

**This was previously written up here as probably-unnecessary — "presence
already ticks every 2 s and carries `heardIds`, so just add three fields to
it". That was wrong**, and the reason is the whole design.

**Presence and audio do not travel the same way.** `needsBroadcastLeg` returns
`true` unconditionally for anything that is not audio, so in the healthy steady
state:

| | broadcast leg | unicast leg |
| :--- | :--- | :--- |
| Presence | always | yes |
| Audio | skipped once peers are known | yes |

Presence therefore travels a *superset* of audio's path, and any health signal
carried on it is structurally optimistic about audio. `heardIds` inherits this:
it is set by **any** decoded packet, so a peer reachable by broadcast but not
unicast keeps reporting that it hears us while none of our audio lands.

**Scope.** Total unicast failure was already caught — the send grader sets
`_sendFailingSince` and audio falls back to broadcast. **Partial** failure was
not: that grader treats `failed < attempted` as healthy, so one unreachable
peer among several stayed unreachable indefinitely. Needs **3+ participants**,
which is why two-phone field tests never surfaced it.

- [x] [`PeerPingTracker`](lib/feature/transfer/domain/service/peer_ping_tracker.dart) —
      per-peer confirmation and RTT, 6 s grace (six missed pings)
- [x] [`ControlPacket`](lib/feature/transfer/domain/entity/control_packet.dart) —
      ping/pong on wire types `0x0A`/`0x0B`, carrying token, `lastTxSeq`,
      `lastRxSeq`, `audioRxPackets`. A **separate hierarchy** from `WakiPacket`,
      so the cubit's sealed switch and the point-to-point transports are
      untouched; the transport answers pings itself and yields nothing
- [x] Sent **unicast only**, deliberately *not* `_sendToAllTargets` — a ping
      answered over broadcast would confirm the one path we are not testing
- [x] **The fix, not just the diagnosis:** `needsBroadcastLeg` gained
      `unicastUnconfirmed`, so a heard-but-silent peer puts audio back on the
      broadcast leg and becomes reachable again
- [x] RTT feeds `LinkSignals`; `unicastUnconfirmed` grades the link **weak**
- [x] `rtt=` and `UNICAST-UNCONFIRMED` on the session log line
- [x] Tests: [peer_ping_tracker_test.dart](test/peer_ping_tracker_test.dart)
      (tracker + the broadcast-policy change), control-packet cases in
      [waki_packet_codec_test.dart](test/waki_packet_codec_test.dart), RTT and
      unicast cases in [link_quality_test.dart](test/link_quality_test.dart)

**Still unverified on hardware.** Whether a broadcast-reachable but
unicast-unreachable peer actually occurs on the target hotspots is untested —
AP client isolation and stale ARP both produce it in principle. A 3-party test
with one phone firewalled would settle it.

---

## P1 — Audio quality

Verified current state: Opus is hardcoded to **16 kHz** at
[opus_audio_codec.dart:100,148](lib/feature/transfer/data/codec/opus_audio_codec.dart),
with **no in-band FEC**. The jitter buffer target is a static **100 ms**
([audio_playback_buffer.dart:65](lib/feature/audio/data/audio_playback_buffer.dart)).
`VoxGate` has hangover + preroll but takes a **fixed threshold**
([vox_gate.dart](lib/feature/audio/domain/vox_gate.dart)).

- [ ] **Adaptive Opus profile** — good link: 24/48 kHz higher bitrate; weak link:
      lower bitrate + resilience. Decided locally from loss/jitter/queue depth
- [ ] **In-band FEC + PLC** — highest value item for riding. A lost packet gets
      reconstructed instead of leaving a hole. Retransmission is *not* the
      answer for realtime
- [ ] **Adaptive jitter buffer** — 60–80 ms close Wi-Fi, 80–120 ms hotspot,
      120–180 ms weak. Must not grow unbounded (latency bloat)
- [ ] **Clock drift** — gradual correction already started; verify over long runs
      that neither side starves or overflows
- [ ] **Do not over-suppress** — target is *maximum intelligibility*, not studio
      quality. Aggressive RNNoise + packet loss destroys consonants
- [ ] **Riding preset** — one toggle: moderate RNNoise, controlled AGC, echo
      cancel, VOX for high noise, Opus robust, adaptive jitter, headset priority,
      slightly higher playback gain
- [ ] **Adaptive VOX noise floor** — sample ambient for a few seconds, then
      `threshold = noiseFloor + margin`. Removes manual tuning between a quiet
      room and a highway

---

## P2 — Connection UX

Reduce the primary screen to **Create Room** / **Join Room**, with transport
chosen under the hood (same Wi-Fi → direct; different network → suggest hotspot;
Bluetooth when more suitable). Most of the machinery exists — this is mostly
unification.

- [ ] Create/Join as the primary choice; transport picker demoted to advanced
- [ ] Unified QR carrying `protocolVersion, sessionId, transport, ssid, password, hostAddress`
      (note: `sessionId` here depends on P0 #1)
- [ ] Preflight check (~0.5–1 s): mic, headset, network, audio route — surfaced
      *before* entering the room
- [ ] Self-test mode in settings: record 2 s, play back locally, report active
      route, verify headset, benchmark latency
- [ ] Clearer recovery messaging

---

## P3 — Polish & diagnostics

- [x] **Link quality indicator** — **done**, pulled forward because P0 produced
      the data it needs.
      [`LinkQualityGrader`](lib/feature/transfer/domain/service/link_quality.dart)
      grades `excellent → good → weak → recovering` from the ladder rung,
      stale-epoch drops, duplicate-route drops, blocked sends, a failing send
      socket, and whether peers confirm they hear us. **The worst signal wins**
      rather than an average — a phone nobody can hear must not show full bars
      because everything else looks fine.
      Surfaced as a four-bar meter in the channel header
      ([walkie_header.dart](lib/feature/walkie/presentation/widget/walkie_header.dart));
      the LIVE/OFFLINE word is unchanged, so no new translated strings and the
      grade reads at a glance while riding. Counters reach it through
      [`TransportStats`](lib/feature/transfer/domain/entity/transport_stats.dart),
      cumulative and diffed by the consumer so the 15 s diagnostic log line and
      the 2 s indicator cannot steal each other's windows.
      Tests: [link_quality_test.dart](test/link_quality_test.dart),
      [link_quality_bars_test.dart](test/link_quality_bars_test.dart)
- [ ] **Session summary** — duration, transport, peers, packet stats, duplicates,
      peak jitter, underruns, reconnects, route changes, mic failures
- [ ] **Field Test Mode** (advanced settings) — log `AUDIO`, `NETWORK`, `JITTER`,
      `ROUTE`, `VOX` every 15 s + one-tap export
- [ ] Battery optimization pass

---

## CI — re-enable *(parked)*

> **Parked by decision, not oversight.** Not to be picked up until un-parked.
> `flutter analyze` and `flutter test` pass locally on every commit so far, so
> the risk of deferring is known rather than unmeasured.


[.github/workflows/flutter-build.yml](.github/workflows/flutter-build.yml) is
**entirely commented out**. For a project combining audio, native Android/iOS and
P2P networking, that is the riskiest single line item in this document, and it
should land *before* the large P0/P1 changes rather than after.

- [ ] `dart format` → `flutter analyze` → `flutter test` → Android debug build
- [ ] Android integration tests

**Blocker found while doing P0:** `dart format` currently rewrites **65 files
that nobody has touched** — the tree predates the formatter version in the
current SDK. A `--set-exit-if-changed` step would fail on day one. Land the
reformat as its own isolated commit *before* switching CI on, so the noise
never lands in a review diff. `flutter analyze` and `flutter test` are both
clean today (265 tests), so those two can be enabled immediately.

---

## Field test matrix

Prioritize these over new features. Nothing in P0/P1 is "done" until it survives
this list.

- [ ] 30 min stationary call
- [ ] 30–60 min call, **screen off**
- [ ] Intermittent Wi-Fi disconnect / reconnect
- [ ] Hotspot disappearing for a few seconds
- [ ] Headset connect / disconnect mid-call
- [ ] App backgrounded on one device
- [ ] Two simultaneous active interfaces
- [ ] Injected duplicates, artificial jitter, 5 / 10 / 20 % packet loss
- [ ] Host / joiner misselection edge cases
- [ ] 2, 3, 4-party calls on one Wi-Fi
- [ ] 20–30 min continuous VOX in noise
- [ ] **Real motorcycle ride, two phones**

---

## Explicitly out of scope

Smartwatch · backend / accounts / database · cloud rooms & remote signaling ·
social features · WebRTC / web guests (low priority — core value is offline P2P).

> Core focus: **phone-to-phone, no internet, reliable voice.**
