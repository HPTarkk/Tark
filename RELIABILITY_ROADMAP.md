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
| **P1** | Audio quality | **In progress** — 5 of 7 |
| **P2** | Connection UX | Started — 4 of 9 (the unification is untouched) |
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

## P1 — Audio quality *(current)*

### The blocker that shaped this phase

`opus_dart` cannot do FEC, and finding out why decided the whole approach.

The package **never binds `opus_encoder_ctl`** — its FFI wrapper covers only
`opus_encoder_get_size/create/init/encode/destroy` — and it hides both the
native encoder pointer and its own library handle behind private fields, so
there is no seam to reach a CTL through from outside. Bitrate, complexity and
in-band FEC are unreachable through it at any level.

Its **decoder** does expose a `fec` flag, and that cannot work either: the value
it forwards to libopus as `frame_size` — a *sample* count — is computed in
*milliseconds* (`_packetDuration`, returned unchanged by `_estimateLoss`). For
this app's 20 ms frames it passes 20 where libopus needs 320, so every FEC
decode returns `OPUS_BUFFER_TOO_SMALL` and the package turns it into a throw.
The bug is latent for Tark today only because nothing had ever asked it to
conceal a packet.

So both calls are bound directly, against the **same** `libopus` handle
`opus_flutter` already loaded — loading a second copy would put the encoder and
decoder in different library instances, which is a bug that only appears at
runtime. Everything else about `opus_dart` is unchanged.

**Three rungs, each a working codec**, so no native failure can cost more than
the status quo:

1. [`ControlledOpusEncoder`/`Decoder`](lib/feature/transfer/data/codec/controlled_opus.dart) —
   direct bindings. The only rung with FEC or tuning.
2. `opus_dart`'s own encoder/decoder — no FEC, fixed bitrate. Exactly what
   shipped before.
3. Raw PCM16, when libopus did not load at all.

Falling from 1 to 2 is silent and safe by design; falling to 3 stays loud,
because it is not. The bindings are behind a conditional import
([stub](lib/feature/transfer/data/codec/controlled_opus_stub.dart) /
[ffi](lib/feature/transfer/data/codec/controlled_opus_ffi.dart)) so the guest
web build still compiles — verified with `flutter build web`.

### 1. In-band FEC + PLC — **done**

- [x] FEC is enabled once at encoder creation and never turned off. It costs
      nothing at a zero loss budget — libopus spends bits on the redundant copy
      only in proportion to `OPUS_SET_PACKET_LOSS_PERC` — which removes the
      whole class of bug where a link degrades and something forgot to enable
      FEC in time to matter
- [x] [`FecGapTracker`](lib/feature/transfer/domain/service/fec_gap_tracker.dart)
      decides when recovery is possible: **exactly one** missing packet. Opus
      carries a copy of the immediately preceding frame and no further back
- [x] `AudioPacket.recoveredSamples` carries the rebuilt frame, played at
      `seq - 1` **before** the real one. That ordering is what makes it worth
      having: the jitter buffer then sees an unbroken run and never conceals the
      gap with silence, which is what a lost packet used to sound like
- [x] Where the packet carries no FEC data (older peer, or the sender budgeted
      no loss), libopus synthesises a concealment frame instead — the PLC half,
      and still far better than a hole
- [x] Tests: [fec_gap_tracker_test.dart](test/fec_gap_tracker_test.dart)

**The case that took the most care** is ordinary UDP reordering. Given 10, 12,
11, 13: packet 12 correctly recovers 11, then the real 11 arrives late. If the
straggler is allowed to rewind the sequence, 13 then looks like a one-packet gap
and "recovers" 12 — a frame already played, decoded a second time and out of
order. A FEC decode advances the native decoder by a frame, so that does not
merely waste work, it desynchronises the decoder for everything after it. The
sequence therefore only ever moves forward.

### 2. Adaptive Opus profile — **done**, minus the sample rate

- [x] [`PeerLossTracker`](lib/feature/transfer/domain/service/peer_loss_tracker.dart) —
      loss in the direction our voice travels, which **cannot be measured at
      this end**. We count what we sent; only the far end counts what arrived
- [x] [`OpusTuner`](lib/feature/transfer/domain/service/opus_tuner.dart) maps
      loss + RTT to bitrate / complexity / loss budget, applied on the 1 s ping
      tick. No hysteresis, deliberately: `OPUS_SET_BITRATE` is a per-frame-cheap
      operation libopus is built to absorb, and damping a change nobody can hear
      would only make the tuning lag the link
- [x] The **worst** peer decides, not the average — one encoded packet goes to
      every peer, so the stream has to survive the worst link it is addressed to
- [x] `txLoss=` and `fec=` on the session log line
- [x] Tests: [peer_loss_tracker_test.dart](test/peer_loss_tracker_test.dart),
      [opus_tuner_test.dart](test/opus_tuner_test.dart)

**The measurement was already on the wire.** P0's unicast ping/pong has carried
`audioRxPackets` since it was written, and `ControlPacket` has said all along
that comparing it against the sender's own count is "a direct loss measurement
that neither end could make alone". Until now those counters were sent,
answered, and thrown away — only the token was read, for RTT. This is the
consumer they were put there for.

**Not done: the 24/48 kHz half.** That is not a codec setting. The capture chain
is 16 kHz end to end (`kTxSampleRate` — the mic resampler targets it,
`AudioProcessor` is built at it, and a frame is 320 samples because of it), so
raising it is a pipeline change on both ends plus a wire-format negotiation.
Audio **bandwidth** is also deliberately left at libopus's own choice rather
than narrowed on a weak link: stripping the high end is where consonants die,
which is the exact trap the "do not over-suppress" item warns about. Loss is
answered with redundancy instead.

### 3. Adaptive jitter buffer — **done**

- [x] The target depth now tracks the link instead of sitting at a static
      100 ms, which is wrong twice over: needless delay for two phones on one
      desk, too shallow for a hotspot between two moving bikes
- [x] Bounds are anchored to the user's setting (×0.6 to ×1.8) rather than fixed
      in milliseconds, so the default 100 ms lands exactly on the roadmap's
      60–180 ms band while someone who raises the slider raises the whole range
      with it, instead of being quietly overruled back down
- [x] **Growth and shrink are not symmetric.** Too shallow is audible
      immediately — the drain stops and speech is chopped — so the depth grows
      *on the underrun itself*, not at the next window. Too deep is a delay
      nobody notices in a sentence, so it is only given back after five clean
      windows (10 s)
- [x] A reset (reconnect) keeps the learned depth: a reconnect mid-ride is
      overwhelmingly the same link, and relearning would be paid for in
      underruns to save a latency nobody notices
- [x] Tests: [audio_playback_buffer_adaptive_test.dart](test/audio_playback_buffer_adaptive_test.dart)

Growing on the underrun rather than on a tick also avoids a trap: the drain
timer is cancelled while the queue refills, so a buffer that is underrunning
constantly barely advances its tick count, and a purely tick-driven adaptation
would grow slowest in exactly the conditions needing it most.

**The drain cadence is untouched.** Adaptation moves the target depth and
nothing else — see the standing warning in
[audio_playback_buffer.dart](lib/feature/audio/data/audio_playback_buffer.dart)
about why the fixed cadence must not be "improved".

### 4. Adaptive VOX noise floor — **done**

- [x] [`NoiseFloorTracker`](lib/feature/audio/domain/noise_floor_tracker.dart) —
      tracks ambient level, moving down fast and up slowly, and **excludes
      frames that are clearly speech** so a long sentence cannot drag the floor
      up behind it and close the gate on the speaker's own voice mid-sentence
- [x] The "zero means VOX off" contract is preserved exactly — no measured
      background may override it
- [x] The result never goes *below* the user's setting. The slider is a
      statement about what they do not want transmitted; a measurement may raise
      the bar to clear a noisy background but not lower it past their own floor
- [x] Capped at the top of the slider's range, so a mic fault reporting an
      enormous level cannot set a threshold no voice could cross — that would be
      a silently muted phone, which is the failure this whole area exists to
      avoid
- [x] Tests: [noise_floor_tracker_test.dart](test/noise_floor_tracker_test.dart)

The fuller answer — reframing the slider itself from an absolute threshold into
a pure margin above the floor — changes what a persisted setting means and
needs the label, the translations, the README and the website with it. It was
originally filed against the riding preset below, on the grounds that both
touch the same four surfaces. **Deliberately not done there.** That was a
batching argument, not a dependency, and reinterpreting a stored 0–0.15 value
as a margin silently changes the gate on every existing install. Landing it
alongside the preset would make the first field report of a misbehaving mic
unattributable to either. Still open, on its own.

### 5. Riding preset — **done**

One switch, on the *main* Settings page rather than under Advanced with the
sliders it overrides — for this audience it is the most consequential control
on the screen.

- [x] [`AudioProfile.resolve`](lib/core/settings/audio_profile.dart) — the
      single seam between stored preferences and the audio chain. Both
      consumers (`AudioEngineImpl` for jitter depth + playback gain,
      `WalkieTalkieCubit` for VOX + cleaner) read the resolved profile, so
      "preset on" reaches all of it or none of it. A caller reading a raw
      preference would half-apply it, which is worse than not having the feature
- [x] **Override, never overwrite.** No preset value is ever written to prefs;
      every slider comes back untouched. That is what makes it safe to try at a
      red light, and it is asserted end-to-end through real `SharedPreferences`
- [x] `PlaybackGain` — a soft knee asymptotic to full scale, continuous in
      value *and* slope, returning its argument identically at unity so the RX
      hot path pays nothing. Hard-clamping a boost is square-wave distortion
      across the consonant band: louder and *less* intelligible
- [x] The Advanced page stops contradicting the switch — overridden controls
      report the running value, say why, and go inert. `_CleanerOption` grew
      `locked` as distinct from `enabled`: the engine that *is* running must
      keep reading as selected, only the alternatives dim
- [x] "Reset to normal" turns the preset off as part of the reset — otherwise
      it restores three values the preset immediately overrides again, and
      reads as a broken button
- [x] `riding` on the transmit log line, so a field-test log says which profile
      produced its VOX figures
- [x] fa + en strings, README, website FAQ (+ the mirrored JSON-LD)
- [x] Tests: [audio_profile_test.dart](test/audio_profile_test.dart),
      [playback_gain_test.dart](test/playback_gain_test.dart),
      [riding_preset_settings_test.dart](test/riding_preset_settings_test.dart)

**The finding that gave the preset its point.** The roadmap listed eight things
for it to switch on; six were already permanent — echo cancel, AGC and NS are
bound to every capture session, headset priority is `configureVoice`, jitter
adaptation and Opus retuning run off measured conditions regardless. So the
preset does not pretend to toggle them.

What was left turned out to matter more than the list suggested. **VOX ships at
0, and 0 means the gate is off entirely** — so on a stock install P1 §4's
adaptive noise-floor tracking *never runs*, because there is no gate for it to
move. At a desk that is the right default. At speed it means the rider holds
the channel open on wind noise for the whole ride with nothing on their own
phone saying so. Arming that gate is the preset's real work, which is why its
VOX value is deliberately *low* — it is the floor beneath the adaptive
threshold, not the threshold.

**Unverified on hardware**, like P0 §4: the gain, the depth anchor and the
suppression strength are reasoned, not measured. They are the field matrix's
"real motorcycle ride" line item's first job.

### Still open

- [ ] **Clock drift** — gradual correction already started; verify over long runs
      that neither side starves or overflows. A field-test item, not a code one
- [ ] **Do not over-suppress** — target is *maximum intelligibility*, not studio
      quality. Aggressive RNNoise + packet loss destroys consonants. Honoured as
      a constraint in the four decisions above (bandwidth left alone, loss
      answered with redundancy, complexity kept modest, and the riding preset
      running RNNoise at 0.65 alone rather than cascaded at full strength);
      still owed a pass over the suppressor defaults themselves
- [ ] **VOX slider as a pure margin** — see the note under §4. Split out of the
      riding preset on purpose; needs a migration story for stored values

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
- [x] **A host announces itself only on its own AP.** Found in a field test:
      host on home Wi-Fi *and* hosting, joiner on the AP, both entered the
      channel, neither ever heard the other — two halves of one session on two
      subnets, both screens reporting an empty room while every other
      diagnostic read healthy. The discovery posture sprays every private
      subnet, which is right while looking for peers and wrong for a host that
      already knows where they are.
      [`HostSubnetFilter`](lib/feature/transfer/domain/service/host_subnet_filter.dart)
      drops the subnet of a network we are only a client of, keyed on the
      client address read from `WifiManager` — interface names can't tell an AP
      apart (`ap0`/`swlan0`/`wlan1` by vendor) but the STA address is by
      definition not the AP. Never filters to empty: on a single-radio phone
      the client side is torn down as the AP rises, and a stale read can name
      the only subnet currently visible.
      Tests: [host_subnet_filter_test.dart](test/host_subnet_filter_test.dart)
- [x] **"Turn Wi-Fi off" advice on the host screen.** A local-only hotspot and
      a Wi-Fi client connection are one radio on most phones, so a remembered
      network drifting back into range makes the framework hand the radio over
      and tear the AP down — arriving as an ordinary `onStopped` with nothing
      marking the cause. `isStaApConcurrencySupported` (API 30+; read as "can't"
      below that) answers it *before* the failure, so the note appears while the
      QR is still up.
      [`HotspotWifiAdvice`](lib/feature/transfer/domain/service/hotspot_control.dart)
      decides, [`HotspotWifiNote`](lib/feature/transfer/presentation/widget/hotspot_wifi_note.dart)
      says it: an animated one-radio-two-claimants diagram that resolves back to
      the healthy state rather than resting on failure, plus the objection
      answered before it is raised ("your channel keeps working — it runs over
      the hotspot, not over Wi-Fi"). The app **cannot** flip the switch —
      `setWifiEnabled` is a no-op for non-system apps since API 29 — so
      `Settings.Panel.ACTION_INTERNET_CONNECTIVITY` floats the toggle over the
      app, keeping the code on screen for the other phone. A teardown
      un-dismisses the note and turns it from prediction into explanation.
      Tests: [hotspot_wifi_advice_test.dart](test/hotspot_wifi_advice_test.dart)
- [ ] Self-test mode in settings: record 2 s, play back locally, report active
      route, verify headset, benchmark latency
- [x] **Join screen stops contradicting itself.** `hotspot_join_instructions`
      rendered unconditionally above the phase switch, so it stayed up through
      every later state — over a spinner while joining, and over
      "joined <ssid>" once already on the network, telling the user to do a
      thing they had just finished. Now shown for `JoinPhase.idle` only; every
      other phase already says something specific of its own.
- [x] **Joiner loading + success are animated**
      ([hotspot_join_states.dart](lib/feature/transfer/presentation/widget/hotspot_join_states.dart)).
      A stock `CircularProgressIndicator` was the only thing on this journey
      not speaking the app's language. Replaced by one state-driven header
      graphic that cross-fades: amber Wi-Fi arcs pulsing outward while
      associating, a green node with slow listening rings once on the network.
      Deliberately calm rather than triumphant — the peer still has to arrive,
      and the celebration belongs to `LinkEstablished` when the channel opens.
      Ring weights were tuned against a render, not by eye: the first pass was
      invisible at the size it actually draws at.
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
- [x] **Connect-success moment** — [`LinkEstablished`](lib/core/widget/link_established.dart)
      replaces the check-in-a-circle each transport had its own copy of: two
      peers close, a beam locks and pulses, the pair resolves into a ring, the
      check strokes in. One painter, no blurs, for the low-end 60 fps floor.
      **The hotspot flow never actually showed it** — `_enterChannel` navigated
      on the same frame it was called, so the animation was built and thrown
      away undrawn, while Bluetooth and the guest link both held the beat.
      All four routes into the channel (the peer arriving on its own, plus the
      "Enter channel" buttons on plain Wi-Fi, hotspot host and hotspot join)
      now go through one delaying `_enterChannel`. A first attempt held the
      beat only for the automatic path, on the theory that delaying a
      deliberate tap reads as lag — wrong, because the join flow's button
      appears at `JoinPhase.joined`, i.e. immediately after associating with
      the host AP, so tapping it *is* acknowledging a connection. The three
      hardcoded `900`s are now `LinkEstablished.hold`, derived from the
      animation's own length so the waits cannot drift from the choreography.
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
