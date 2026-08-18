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
| **P1** | Audio quality | **Done** — every code item; clock drift is a field test |
| **P2** | Connection UX | Started — 6 of 11 (Create/Join + the channel id landed) |
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

**Done**, as a per-sender *session epoch* rather than a shared channel id:

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
distribution channel. A shared channel id answers a different question ("are we
in the same channel as those other people"), needs the QR/credential plumbing
that is itself P2 work, and would have blocked this behind it. The two compose:
a channel id can be added in P2 without revisiting any of the above.

Deferred with the rest of the QR work, and now landed there:

- [x] Shared channel id in the QR / hotspot credentials, to keep two adjacent
      channels on one Wi-Fi apart — see P2 §2, as
      [`ChannelId`](lib/core/identity/channel_id.dart). It composed exactly as
      predicted: the epoch was not revisited

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

## P1 — Audio quality *(code complete)*

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
- [x] ~~The result never goes *below* the user's setting~~ — superseded by §7,
      which is what this bullet was hiding: taking the max of a stored absolute
      and the measured one meant the stored value won for everyone who had
      turned the slider up, and they never got the adaptation at all
- [x] Capped, so a mic fault reporting an enormous level cannot set a threshold
      no voice could cross — that would be a silently muted phone, which is the
      failure this whole area exists to avoid
- [x] Tests: [noise_floor_tracker_test.dart](test/noise_floor_tracker_test.dart)

The fuller answer — reframing the slider itself from an absolute threshold into
a pure margin above the floor — changes what a persisted setting means and
needs the label, the translations, the README and the website with it. It was
originally filed against the riding preset below, on the grounds that both
touch the same four surfaces. **Deliberately not done there.** That was a
batching argument, not a dependency, and reinterpreting a stored 0–0.15 value
as a margin silently changes the gate on every existing install. Landing it
alongside the preset would make the first field report of a misbehaving mic
unattributable to either. Done on its own, as **§7** below.

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

### 6. Do not over-suppress — **done**

Was carried as a standing constraint honoured by four other decisions
(bandwidth left alone, loss answered with redundancy, complexity kept modest,
the riding preset running RNNoise at 0.65 alone rather than cascaded at full
strength), and owed a pass over the suppressor defaults themselves. The pass
found the constraint being broken in the two places nobody had looked.

**The stock default was more aggressive than the riding preset.**
`AppSettings.defaults()` shipped `noiseSuppression: 1.0`, justified in its own
comment as compensation for VOX being wide open — which is the over-suppression
trade in its purest form. So a default install ran the exact setting the
tuned-for-a-motorcycle profile documents itself as backing away from, and ran it
in the environment with the *least* noise to justify it: at a desk there is the
least to remove and therefore the worst ratio of speech damaged to noise gained.
The damage does not scale with the ambient level; the benefit does.

**The cascade doubled up.** `NoiseSuppressionEngine.both` has always been
described as RNNoise first, then spectral subtraction "to mop up any residual
steady hum" — and was implemented as two cleaners at the same full slider value.
The residuals multiply, and worse, the second stage subtracts against a signal
whose remaining noise is no longer the stationary kind its floor tracker
assumes, so it over-subtracts, into speech.

- [x] [`SuppressionPlan`](lib/core/settings/suppression_plan.dart) — one pure
      resolver from *(engine, strength, is the native denoiser available)* to
      which stages run and what strength each gets. `ceiling` (0.65) is now the
      most any shipped configuration asks for, read by both the stock default
      and `RidingPreset` rather than written out twice
- [x] The preset's cleaner value stops being a *lowering* and becomes a **pin**:
      a rider who dragged the slider to 100 % is pulled back for the ride and
      finds their own value untouched when they switch it off
- [x] A running cascade gives its second stage `mopUpShare` (half) of the
      slider. Keyed on the cascade actually **running**, not on `both` being
      selected — with the native library missing, `both` collapses to spectral
      alone, and halving a lone cleaner there would be a second silent downgrade
      on precisely the devices that already lost the better engine
- [x] The engine/availability branching moved out of the mic callback, where it
      ran per buffer, into the plan — rebuilt only when one of its three inputs
      changes (including after `_openStreams`, since `RnnoiseSuppressor.reset`
      recreates the denoiser and availability can change there)
- [x] Tests: [suppression_plan_test.dart](test/suppression_plan_test.dart) —
      the full engine × availability matrix, plus the two invariants the pass
      exists to hold: nothing shipped exceeds the ceiling, and the default is
      never more aggressive than the riding preset
- [x] README: the "bounded noise cleaning" bullet in the audio pipeline

**One slider, two engines that do not mean the same thing by it.** Spectral's
0..1 is an aggression curve (over-subtraction factor 2→4, attenuation floor
0→−30 dB); RNNoise's is a dry/wet mix. That is why the mapping needs a resolver
that knows both rather than one `clamp` writing the same number into each, which
is what `setNoiseSuppression` used to do.

**No migration needed, deliberately.** The stored value wins where one exists,
so an install that ever touched the slider keeps its own choice — that is the
user's decision and not ours to revise. Installs that never touched it read the
default through `SettingsRepositoryImpl`'s `?? AppSettings.defaults()` fallback
and pick the new value up on next launch.

**Left undone on purpose.** The roadmap line reads "aggressive RNNoise **+
packet loss** destroys consonants", and P1 §2 now measures far-end loss on the
ping/pong. Backing the cleaner off on a lossy link is therefore buildable —
and is not built here, because it would make the mic path move with network
state, and loss is already answered where the evidence points, with FEC. The
suppressor curves themselves (β 2→4, −30 dB floor at full strength) are also
untouched: changing a DSP curve without a measurement is how the 1.0 default got
written in the first place.

### 7. VOX slider as a pure margin — **done**

Filed against §4 as "the fuller answer", split out of the riding preset on
purpose, and held back on the grounds that it needed a migration story for
stored values. It did. Here it is.

**Why the half-answer was worse than it looked.** `thresholdFor` returned
`max(userValue, floor × 2.5)` — two settings in one control, and the wrong one
usually won. A stored value above roughly 0.06 beats `floor × 2.5` in any room
quiet enough to hold a conversation, so for everyone who dragged the slider
up — the people who found the gate twitchy, i.e. **exactly the people the
adaptation was written for** — the measured background was never consulted at
all. The adaptation only ever reached users who had left the slider low.

- [x] [`VoxMargin`](lib/core/settings/vox_margin.dart) — the slider stores a
      distance above the background, 3–18 dB, and the measured floor supplies
      the level. The fixed 2.5 × (≈ 8 dB) everyone has been running lands at
      about a third of the slider, so there is room either way from the
      behaviour people already know
- [x] Zero still means **off**, unchanged and deliberately *not* a point on the
      dB scale: `isOff` is asked first, by the tracker, by `VoxGate`, and by the
      migration
- [x] `NoiseFloorTracker.thresholdFor(margin)` is now pure margin × floor. It
      fails **open** before the first frame — a clipped word costs less than a
      phone that is quietly mute
- [x] **The hazard the reframe introduces**, and the one thing that had to hold
      it off: a margin is a multiplication, and the platform suppressor on some
      phones hands back frames of exact digital silence between words (the
      Galaxy S8+ measured in `VoxGate`'s doc: 301 of 800 frames). Those zeros
      drag the estimate down and would disarm the gate by arithmetic, on
      precisely the devices whose mics behave worst. The old absolute slider hid
      this because the user's own number sat underneath; a pure margin has
      nothing underneath, so `_minFloor` (≈ −54 dBFS) refuses to believe
      silence. Below any real acoustic background, so it never raises the bar in
      a room someone is actually speaking in
- [x] `RidingPreset.voxMargin` = 0.5 (≈ 10.5 dB). The old 0.02 was tiny on
      purpose — on an absolute scale anything higher would out-shout the
      tracker and clip word onsets indoors, so the preset could only arm the
      gate and get out of the way. A margin cannot out-shout the tracker, it
      *is* the tracker's setting, so the preset finally states one
- [x] `processForTransmit` now receives the **resolved** level rather than the
      stored setting. It was already slightly wrong (the expander ran off the
      raw value while VOX ran off the adaptive one); with a margin it would have
      been nonsense arithmetic. Both cubits resolve once per frame and pass the
      same number to the gate and the expander
- [x] `vox=` on the transmit log line now carries margin, dB, measured floor and
      resolved gate level. A field report of "it kept cutting me off" is
      unattributable with fewer: the setting alone cannot say what the mic was
      hearing, and the level alone cannot say whether the rider or the room
      chose it
- [x] Tests: [vox_margin_test.dart](test/vox_margin_test.dart) (scale,
      migration, read-back), rewritten threshold group in
      [noise_floor_tracker_test.dart](test/noise_floor_tracker_test.dart)
- [x] fa + en strings (one new hint line under the slider), README

**The migration story: the number on the slider does not move.** The old control
ran 0 – 0.15 and drew itself as 0 – 100 %, so the conversion is the percentage
the user was actually looking at — 60 % stays 60 %, now meaning 12 dB above the
room rather than an absolute 0.09. That is the best available answer, because
the one thing needed to convert properly, *how loud their room was*, is exactly
what the old setting never recorded. Off maps to off exactly; an update must not
arm a gate someone left disarmed.

It is a **read-through**, not a rewrite: `vox_margin` is the new key, the legacy
`vox_threshold` is translated on every read until the slider is next touched,
and never written. No write racing a read, nothing half-finished if the process
dies mid-migration, and a downgrade to an older build still finds its own key
intact. `SettingsModel.readVoxMargin` is the single reader, shared by `loadAll`
and the getter so the settings page cannot draw one value while the engine runs
another.

**Not done: the label.** "HOW LOUD TO START" survives the reframe intact — it is
still how loud you have to be — so the change is carried by one added hint line
("measured against the room, so one setting works parked and at speed") rather
than by re-cutting a string that is already right in both languages. The website
never described the VOX control at all, so it needed nothing.

### Still open

- [ ] **Clock drift** — gradual correction already started; verify over long runs
      that neither side starves or overflows. A field-test item, not a code one

---

## P2 — Connection UX

Reduce the primary screen to **start a channel** / **join a channel**, with transport
chosen under the hood (same Wi-Fi → direct; different network → suggest hotspot;
Bluetooth when more suitable). Most of the machinery exists — this is mostly
unification.

The unification itself landed first (§1 below), because the two items after it
both need it: the unified QR is produced by Create and consumed by Join, and
the preflight check needs one funnel into the channel to sit in rather than
four call sites to be re-placed across.

> **"Room" is not a word this app says.** The review's wording is kept above
> because it is the review's, but the product has called this thing a
> **channel** since its first screen — `JOIN CHANNEL`, `LEAVE CHANNEL`,
> `channel_members`, the channel header, in both languages — and shipping
> "room" alongside it would have been two words for one concept in a two-tap
> flow. Everything built for P2 §1 and §2 is therefore named `Channel*`
> (`ChannelIntent`, `ChannelPlan`, `ChannelActions`, `ChannelId`,
> `ChannelGate`). Read "Create Room / Join Room" below as **start a channel /
> join a channel**.

- [x] **Create/Join as the primary choice; transport picker demoted to
      advanced.** The screen opened on `WIFI / HOTSPOT · BLUETOOTH · GUEST` —
      a question about where the two phones are and what is around them, which
      the app measures continuously and the person holding one phone has to
      guess at. Worse, the answer lived in Settings, so it outlived the
      situation that produced it, and two riders in a field with no Wi-Fi had
      to leave the main screen before the app would do the only thing that
      could work there.

      So the axis is inverted. The one question left on screen is the one the
      user is the sole authority on — *am I starting this, or arriving?* — and
      [`TransportAdvisor`](lib/feature/transfer/domain/service/transport_advisor.dart)
      derives the transport from observable facts, on every tap rather than
      once and forever. The ladder is a shared network, then a hotspot, then
      Bluetooth, then a self-reported dead end; each rung is refused rather
      than guessed at, so **automatic can never produce a blocked plan while
      any rung is available** (asserted).

      **The asymmetry is why the two intents cannot share one capability
      flag.** `canHostHotspot` and `canJoinHotspot` differ on iOS, which can
      walk onto an access point it could never have raised — so the same phone
      in the same room resolves to a hotspot for *join* and Bluetooth for
      *start*. A single "supports hotspot" bool would have been wrong for one
      of them on every iPhone.

      Each action names its route underneath itself, keyed on
      `RoomPlanReason` rather than on the transport: the two hotspot ends are
      the same transport and opposite instructions, and one "over a hotspot"
      line would be wrong for whichever end read it. A decision made silently
      is indistinguishable from a decision made wrong — a rider who taps START
      and watches a hotspot come up needs to know that was the plan.

      **The pin is a second key, not the same one.** `transport_mode` keeps
      meaning "what is in effect" (the DI factory and quick access read it
      synchronously at cold start); `transport_pin` is new and means "what the
      user asked for", absent for automatic. Collapsing them would force
      automatic to store a transport to be automatic about. It also decides
      the upgrade: reading the pin with `TransferMode.fromKey` — which answers
      Wi-Fi for an absent value — would have silently pinned **every existing
      install** and made the advisor dead code on upgrade. `_readPin` refuses
      that, and the test that fixes it in place is the first one in the file.

      The same trap sat in onboarding, whose transport beat opened with Wi-Fi
      already lit: every first run would have ended by writing a preference
      nobody chose. AUTOMATIC now leads the beat and is pre-selected, and the
      beat writes a *pin*, so walking past it leaves the advisor free.

      - [x] [`RoomIntent`](lib/feature/transfer/domain/entity/room_intent.dart),
            carried into the next screen as a query parameter so the hotspot
            bridge and the Bluetooth page stop re-asking "are you the host?"
            one screen after it was answered. Applied through `chooseRole` /
            the page's own permission gate, never by pre-seeding state, so a
            preselected side still takes the side-exclusivity teardown, the
            role-store write and the Android permission request. An unknown
            key is *no* intent rather than a default one — a guessed side
            starts an access point nobody asked for
      - [x] [`RoomActions`](lib/feature/landing/presentation/widget/room_actions.dart) —
            Create leads with the fill, the border pulse and the glow, Join is
            the same shape drawn quietly. Deliberately not equal weight: there
            is nothing to join until someone starts, so leading with Create
            answers the question two identical buttons would leave the user
            standing in front of. The glow is inside a `RepaintBoundary`, since
            it repaints every frame of the breath and the low-end floor is a
            Galaxy S8+
      - [x] The identity card reads its icon and READY/no-network off the plan
            instead of `state.transferMode`, which under automatic is the
            *last* transport used and says nothing about the next one
      - [x] **"Not on the same network?"**, under the pair and only while the
            plan assumed one network — the single thing the advisor provably
            cannot check is whether the *other* phone is on this one. Still
            offered for a hand-pinned Wi-Fi with no network, because that is
            the only route off the screen and a pin is a preference, not
            grounds for stranding someone
      - [x] Picker moved to Advanced settings with AUTOMATIC as a first-class
            default option, and the landing chip says which is in force. A pin
            that stops suiting the situation is otherwise indistinguishable
            from the app choosing badly, and the difference decides whether
            someone changes a setting or files a bug
      - [x] Entitlement is checked in the UI before committing, as the picker
            already did, rather than having automatic quietly route somewhere
            cheaper. (Parked, so a no-op today — it is there so un-parking does
            not have to find the call site.) A paid *pin* that loses
            entitlement falls back to automatic, not to Bluetooth: rewriting it
            would put a hand-picked value in a slot the user never touched, so
            a later purchase would restore nothing
      - [x] fa + en strings, README (feature bullet, "which transport should I
            use", Settings and onboarding bullets), website FAQ + the mirrored
            JSON-LD, `node scripts/build-website-i18n.mjs` re-run
      - [x] Tests: [transport_advisor_test.dart](test/transport_advisor_test.dart)
            (the full ladder, the iOS asymmetry, pin short-circuiting, the
            never-blocks property), [transport_pin_test.dart](test/transport_pin_test.dart)
            (the upgrade path, pin/mode independence, entitlement demotion),
            [room_actions_test.dart](test/room_actions_test.dart) (what each
            button says and hands back, plus no overflow at 320 px in both
            languages)

      **Unverified on a device.** The layout is asserted by widget test at
      320 px in fa and en, and the routing by unit test, but nothing here has
      been run on hardware — the repo has no landing preview harness and the
      full web target does not build.

- [x] **Unified QR carrying `protocolVersion, sessionId, ssid, password`** —
      and, with it, P0 §1's deferred half: a shared channel id, so two groups
      on one café Wi-Fi stop hearing each other. The transport had no idea of a
      channel at all; "the channel" meant "the subnet", so everything on that
      LAN heard everything else by construction.

      **The design problem was that the existing QR is a *standard Wi-Fi* QR**,
      and that is load-bearing: iOS Camera and Android's own scanner both offer
      a one-tap "join this network" when they read it, which is the fastest
      route onto a hotspot the app has. A Tarkk-specific payload would have
      bought the channel id at the cost of that path. So the channel rides
      **inside** the Wi-Fi payload as a `TARK1:` field. The format is a list of
      `KEY:value;` pairs and scanners skip keys they do not know — not an
      assumption but the format's own history, since WPA3 added `K:` and every
      pre-existing scanner had to keep working. The version lives in the *key*
      rather than the value, so a future `TARK2:` is an unknown key to this
      build (ignored, open channel) rather than a value it would misparse.

      - [x] [`ChannelId`](lib/core/identity/channel_id.dart) — 24 bits shown as
            six hex characters, because it is read aloud through a helmet at
            least as often as it is scanned. `ChannelId.open` (zero) is a legal
            value meaning "I have not asked to be separated from anyone"
      - [x] [`ChannelGate`](lib/feature/transfer/domain/service/channel_gate.dart) —
            admits when the ids match **or either side is open**. Only
            *named ≠ named* drops anything
      - [x] Wire v4 (`0x0C/0x0D/0x0E`) carries it after the epoch, for the same
            reason the epoch is in the header: an audio packet ends in a
            variable-length payload, so nothing can be appended to it. Presence-
            only would have admitted a neighbouring channel's audio until its
            next presence tick — up to two seconds of someone else's
            conversation
      - [x] **v4 is emitted only while a channel is named.** Every zero-setup
            Wi-Fi session, every Bluetooth link and every browser guest keeps
            sending v3, byte for byte what it sent before — asserted. The four
            bytes are real on the transport that can least afford them (RFCOMM
            caps in-flight audio writes), and a version bump that costs
            bandwidth should be paid by packets that carry something for it
      - [x] Gated in the Wi-Fi receive path *before* the epoch gate: a packet
            from another conversation is not a peer of ours at all, so it must
            not claim a slot in the epoch gate's per-sender map any more than
            it may refresh the peer map, heard list or route pin
      - [x] `channel=` on the session log, plus `otherChannels=N(M pkts)` when
            we are excluding anyone. That counter is the only drop class that
            is *good* news — it says there is a second group in earshot and we
            are correctly ignoring them, which is exactly the question behind
            "why can't my friend hear me on this Wi-Fi"
      - [x] Start-a-channel names one; join deliberately does not, and stays
            open. A joiner who has not scanned has said nothing about which
            conversation they are in, and inventing one for them would exclude
            them from every group on the network including the one they meant
      - [x] Tests: [channel_id_test.dart](test/channel_id_test.dart) (value,
            gate, membership, both payload shapes), plus a `channel id` group in
            [waki_packet_codec_test.dart](test/waki_packet_codec_test.dart)
      - [x] fa + en strings, README, website FAQ + mirrored JSON-LD

      **What this is not.** The id travels in clear on every packet and anyone
      can set theirs to match, so it separates channels and does not protect
      them. Calling it privacy would be the kind of claim that stops people
      taking the real limits seriously.

      **The half that is left**, and it is the half that closes the café case
      completely: on plain Wi-Fi there is nowhere yet to *show* a code or type
      one in — the host screen that displays it only exists in the hotspot
      flow. So two groups are separated as soon as one person in each has
      started a channel, but a joiner who tapped straight through still hears
      both. The intended answer is not a mandatory pairing step: the transport
      can already see it is excluding traffic (`otherChannels`), so the channel
      screen can offer "2 groups here — enter a code" only once there provably
      are two. Filed below.

- [ ] Channel code on plain Wi-Fi: show the host's code in the channel, and
      offer code entry — but only when `otherChannels` proves a second group is
      present, so the zero-setup path keeps costing nothing
- [ ] `transport` and `hostAddress` in the payload. Deliberately left out:
      transport is implied by which payload shape was scanned, and a host
      address is a discovery shortcut rather than a separation mechanism —
      landing it here would make the first field report ambiguous between "the
      channel worked" and "the address hint worked"
- [ ] Preflight check (~0.5–1 s): mic, headset, network, audio route — surfaced
      *before* entering the channel
- [x] **A host announces itself only on its own AP.** Found in a field test:
      host on home Wi-Fi *and* hosting, joiner on the AP, both entered the
      channel, neither ever heard the other — two halves of one session on two
      subnets, both screens reporting an empty channel while every other
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
clean today (512 tests), so those two can be enabled immediately.

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

Smartwatch · backend / accounts / database · cloud channels & remote signaling ·
social features · WebRTC / web guests (low priority — core value is offline P2P).

> Core focus: **phone-to-phone, no internet, reliable voice.**
