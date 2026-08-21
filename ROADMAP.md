# Tark HD Audio & Reliability Roadmap

Derived from the 2026-08-19 two-device motorcycle field test and tracked as
GitHub issues [#26–#33](https://github.com/HPTarkk/Tark/issues) on `HPTarkk/Tark`.
This file is the cross-session checkpoint — each phase below is one GitHub
issue, kept in execution order with its dependencies, required work, and
acceptance criteria condensed so a later session can pick up without
re-reading all 8 issues in full.

Supersedes `RELIABILITY_ROADMAP.md` (removed) — that plan's P0–P3 items landed;
this is the next workstream.

> **Baseline validated in the field:** connect → pocket both phones → screen
> off → talk + share music → transient link disturbance → automatic recovery
> → keep riding without touching the phones. That behavior is now the
> regression gate (#26) for every phase below.

**No rewrite.** HD Voice, HD Music, and stream separation build incrementally
on the existing offline-first architecture. No server dependency is
introduced anywhere in this workstream.

---

## Status at a glance

Issues 1/8 through 6/8 (#26–#31) have landed — see their own checkpoint
commit history. 7/8–8/8 (#32–#33) are next.

| # | Issue | Priority | Focus | Depends on |
| --- | --- | --- | --- | --- |
| 1/8 | [#26](https://github.com/HPTarkk/Tark/issues/26) | P0 | Lock the field-test reliability baseline | — |
| 2/8 | [#27](https://github.com/HPTarkk/Tark/issues/27) | P0 | Fix cumulative transport-stat semantics (Link Quality) | can parallel #26 |
| 3/8 | [#28](https://github.com/HPTarkk/Tark/issues/28) | P0 | Negotiated 24 kHz HD Voice | #26, #27 |
| 4/8 | [#29](https://github.com/HPTarkk/Tark/issues/29) | P0 | HD Shared Music codec/profile | #26, coordinate w/ #28 |
| 5/8 | [#30](https://github.com/HPTarkk/Tark/issues/30) | P0 | Independent Voice/Music transport streams, voice-first QoS | #26, #27, #28, #29 |
| 6/8 | [#31](https://github.com/HPTarkk/Tark/issues/31) | P1 | Smart Music Ducking (optional, user-toggle) | #30, #29 |
| 7/8 | [#32](https://github.com/HPTarkk/Tark/issues/32) | P1 | Split adaptive Voice/Media QoS, graceful degradation | #27, #28, #29, #30 |
| 8/8 | [#33](https://github.com/HPTarkk/Tark/issues/33) | P1 | Pre-ride Preflight check | #26, #27, #28–#30 |

Execution order is strict for the P0 spine (1→2→3→4→5); #31/#32 can overlap
each other once #30 lands; #33 must come last since it reports on the final
negotiated capability model.

---

## 1/8 — [#26] Lock the motorcycle field-test reliability baseline

**Do first.** No audio redesign in this issue — it exists to make sure later
fidelity work can't silently regress what already works.

- Commit a version-controlled field-test runbook (e.g. under `docs/testing/`):
  two phones, real BT/helmet headsets, rider+pillion, Wi-Fi/hotspot, screen-off
  interval, VOX conversation, shared music, transient network interruption,
  headset disconnect/reconnect, leave/rejoin, diagnostic export from both ends.
  Separate automatable checks from physical-device-only evidence — never fake
  physical evidence in CI.
- Extend `scripts/decode_tark_log.py` (don't invent a second log format) with a
  privacy-safe session-scoped analyzer: duration, negotiated sample rates, RTT,
  loss/blocked-send windows, reconnect/recovery count, codec transitions,
  jitter-buffer counters, MusicMixer counters, background/resume events,
  terminal failures. Must not mix sessions from a multi-session ring log.
- Add deterministic tests: screen-off/resume doesn't cause false mic
  restart/reconnect; transport recovery state transitions; jitter buffer reset
  after real reconnect; music capture lifetime not wrongly coupled to
  foreground UI; no duplicate subscriptions/timers after retry.
- Document provisional field acceptance gates: no manual leave/rejoin for a
  transient recoverable event, no permanent one-way audio after recovery,
  background/screen-off survives, shared music never causes disconnect, no
  unbounded queues/runaway memory/recovery loop, no latency regression.
- **Never commit raw `.tarklog` files** or any device/peer identifiers, IPs,
  SSIDs, or names — aggregate/privacy-safe evidence only.

Acceptance: runbook committed and followable without tribal knowledge;
analyzer is session-scoped; automated tests cover the non-physical invariants;
physical-only checks explicitly marked as owner/field evidence; this baseline
becomes the regression gate for issues 3–7; `flutter analyze` + tests green.

---

## 2/8 — [#27] Fix cumulative transport-stat semantics used by Link Quality

**Bug:** `WifiTransferRepositoryImpl._logSessionState()` resets counters
(`TransportStats` stale-epoch drops, duplicate-route drops, blocked sends)
that `WalkieTalkieCubit._gradeLink()` treats as session-cumulative and diffs
every 2s — producing invalid/negative deltas and wrong Link Quality grading
whenever the logger fires between two samples.

Files: `lib/feature/transfer/data/repository/wifi_transfer_repository_impl.dart`,
`lib/feature/transfer/domain/entity/transport_stats.dart`,
`lib/feature/walkie/presentation/manager/walkie_talkie_cubit.dart`,
`lib/feature/transfer/domain/service/link_quality_grader.dart`.

- Pick one authoritative contract (preferred: `TransportStats` stays
  session-cumulative/monotonic) and document it; keep separate `_...Window`
  counters for the 15s log-only window; only reset cumulative totals at an
  explicit session boundary/generation change.
- Audit `_logSessionState()` and every other transport's `TransportStats` so
  logging never mutates product-facing totals.
- Ensure leave/rejoin, transport replacement, retry-start, or real session
  reset resets `WalkieTalkieCubit`'s `_lastStats` baseline cleanly (no giant
  negative deltas, no stale carry-over) — e.g. reset on new session/repo
  generation, or thread a generation id through stats.
- Tests: counters increase monotonically across logger windows; logging
  never changes totals; cubit sees correct positive deltas; no negative
  quality signal from logging alone; new session starts clean; repeated
  blocked/duplicate/stale events grade correctly per independent 2s window.

Non-goals: retuning Link Quality thresholds, Opus changes, Wi-Fi recovery
redesign, hiding real loss signals for a greener badge.

Acceptance: single documented stats contract; logging can't mutate Link
Quality's counters; no negative deltas from logger cadence; session/rejoin
resets baselines intentionally; regression tests reproduce and fix the old
bug; `.tarklog` stays at least as useful; analyze + tests pass.

---

## 3/8 — [#28] Prototype and ship negotiated 24 kHz HD Voice

**Depends on #26, #27.** Field logs: device opens ~48 kHz capture/playback but
wire voice is hardcoded 16 kHz mono / 20 ms / 320 samples — both riders
described the result as "radio-like." Target: 24 kHz mono HD Voice as the
preferred profile on capable links, 16 kHz kept as a reliable fallback. Do
**not** default to 48 kHz just because the device stream reports it.

Files: `lib/feature/audio/data/audio_engine_impl.dart`,
`lib/feature/audio/domain/resampler.dart`,
`lib/feature/transfer/data/codec/opus_audio_codec.dart`,
`lib/feature/transfer/data/codec/waki_packet_codec.dart`,
`lib/feature/transfer/domain/entity/waki_packet.dart`,
`lib/feature/transfer/domain/service/opus_tuner.dart`,
`lib/feature/audio/data/audio_playback_buffer.dart`,
`lib/feature/walkie/presentation/manager/walkie_talkie_cubit.dart`.

HD profile target: 24 kHz mono, 20 ms → 480 samples/frame, Opus VOIP mode,
FEC where supported, adaptive bitrate re-derived (not copied from the 16 kHz
tuner), no user-facing sample-rate setting.

- Replace hidden "every frame is 16 kHz/320 samples" assumptions with an
  explicit audio-format contract (rate, channels, frame duration,
  codec/profile version) — no scattered `24000`/`480` magic constants.
- Capability negotiation: both ends advertise supported profiles, pick the
  highest mutual safe one, fall back to 16 kHz when the peer lacks HD, no
  packet-by-packet flapping, explicit codec/jitter reset on a legitimate
  transition, diagnostics record the negotiated profile.
- Fix capture/resample/processing chain for a variable negotiated rate: audit
  anti-alias filtering, resampler ratio/state resets, VOX/RMS semantics,
  RNNoise assumptions, frame accumulator sizing, pre-roll/hangover sizing,
  native AEC/NS/AGC, route-change restarts.
- Generalize `OpusAudioCodec` (currently fixed `kOpusSampleRate = 16000`,
  320 samples) to construct per negotiated profile, preserving FEC,
  per-sender decoder isolation, gap tracking, fallback, and reset-on-reconnect.
- Generalize playback/jitter buffer: resample negotiated rate → device output
  rate; make all queue limits/fade lengths/concealment sizes/latency math
  time-based or correctly scaled — no hidden 16 kHz-sized buffers at 24 kHz.
- Add an A/B evidence method (dev/field) logging device rate, negotiated wire
  rate, bitrate/FEC, RTT/loss, underruns/resync/concealment, CPU/memory.
  Subjective listening stays owner/field evidence, never fabricated in CI.

Reliability constraints (non-negotiable, must preserve #26 baseline): no new
screen-off disconnects, no permanent one-way audio after recovery, no
material latency regression, no route-change deadlock, no runaway buffers,
no auto-reconnect regression, 16 kHz fallback stays production-usable. If HD
can't be sustained, fail gracefully to a lower profile rather than
disconnecting.

Non-goals: stereo voice, 48 kHz fullband default, HD music (→ #29), ducking,
new backend, user-facing sample-rate UI.

Acceptance: explicit negotiated-format contract; two capable peers run
24 kHz/20 ms end-to-end; mixed-version pair falls back safely; Opus/FEC/
jitter/resampling work at both rates; diagnostics show actual vs negotiated
rates; tests pass for both profiles; #26 invariants green; physical
motorcycle A/B requested before HD becomes default for all users.

---

## 4/8 — [#29] Build a true HD Shared Music codec/profile

**Depends on #26; coordinate wire/capability work with #28.** Field logs show
Android switches Opus to `OPUS_APPLICATION_AUDIO` for music correctly, but
media still gets re-cut onto the 16 kHz mono voice frame grid at ~20 kbps —
this issue establishes the media-quality primitives and negotiated format
only; #30 makes voice/media independent streams.

Files: `lib/feature/audio/domain/music_mixer.dart`,
`lib/feature/walkie/presentation/manager/walkie_talkie_cubit.dart`,
`lib/feature/transfer/data/codec/opus_audio_codec.dart`,
`lib/feature/transfer/domain/service/opus_tuner.dart`, Android
playback-capture / system-audio bridge code.

Initial target profile: 48 kHz media rate, stereo only when the real capture
path is genuinely stereo (never manufacture fake stereo), 48 kHz mono when
capture is genuinely mono, `APPLICATION_AUDIO`, 20 ms (or justified) frames,
dedicated bitrate range ~64–96 kbps on strong links with evidence-based lower
tiers (48/32 kbps) — starting targets, not immutable.

- Introduce a dedicated media format/profile model (sample rate, channels,
  codec application, frame duration, bitrate-policy identity) instead of
  `OpusEncodeProfile.music` bolted onto a 16 kHz-fixed codec. Coordinate with
  #28 so voice and media share one capability/protocol scheme.
- Audit Android system playback capture + Dart bridge: determine actual
  capture rate/channels, preserve real stereo, keep truthful mono, log
  negotiated/actual format — refactor hardcoded-mono bridges behind an
  explicit format descriptor if needed.
- Media-specific Opus codec support: `APPLICATION_AUDIO`, mono/stereo-aware
  construction, correct 48 kHz frame sizes, no implicit 16 kHz pass-through,
  deterministic fallback on unsupported profile, corruption must not crash or
  tear down the voice session.
- Dedicated media bitrate policy (not the 12/16/20/24 kbps speech ladder):
  strong-link tier, bounded fallback tiers, explicit floor below which media
  should degrade rather than claim "HD," diagnostics show active
  bitrate/profile. Never fund media bandwidth by weakening voice.
- Explicit, testable resampling/channel conversion where unavoidable — avoid
  repeated 48→16→48 round-trips, avoid clipping, preserve frame timing, reset
  state on route/format change.
- Objective fidelity tests with synthetic fixtures (no copyrighted music in
  the repo): frequency sweep/multi-tone bandwidth check, stereo L/R identity,
  mono fallback, multi-minute encode/decode continuity, bitrate/profile
  assertions, no clipping/NaN/Infinity, decoder fallback for unsupported
  capability.
- Keep the current Music Cast start/stop/revocation/error UX working until
  #30 lands; must not reintroduce the historical lag/disconnect issue.

Constraints: no server dependency, no unbounded media buffering, no
UI-isolate allocation storm at 48 kHz/stereo, avoid `List<double>` boxing in
the hot path, measure CPU/network rather than assume, voice must survive
media capture/codec failure, background/screen-off compatible with #26.

Non-goals: final packet scheduling/independent jitter queues (#30), ducking
(#31), full adaptive QoS (#32), DRM/music-service integration, cloud relay.

Acceptance: first-class HD music profile distinct from voice; 48 kHz
end-to-end encode/decode in tests; stereo preserved only when genuine, mono
fallback correct; bitrate materially above the legacy speech ladder; no
forced 16 kHz intermediate; diagnostics expose capture/negotiated
format/bitrate; fidelity/channel tests exist; Music Cast lifecycle tests
green; #26 baseline not weakened.

---

## 5/8 — [#30] Separate Voice and Shared Music into independent transport streams, voice-first QoS

**Depends on #26, #27, #28, #29.** Today music is mixed onto the mic-driven
20 ms voice frame grid — wrong coupling for a product where conversation is
safety-critical and music is enjoyment-critical. No server introduced; this
stays local/offline transport.

- Explicit stream discriminator in the packet protocol (`voiceAudio` vs
  `sharedMediaAudio`), each with independent sequence numbers, decoder state,
  gap/FEC tracking, jitter/buffer state, format metadata, and diagnostics.
  Coordinate with #28/#29's negotiation — don't invent a second versioning
  mechanism.
- Decouple the media clock from microphone callbacks: `MusicMixer` currently
  re-cuts captured audio to the mic's 20 ms grid — media needs its own
  bounded frame scheduler. Mic silence/mute/VOX must not stop media
  scheduling; mic restart must not kill a healthy media stream; media
  stall/revocation must not tear down voice. Refactor/retire `MusicMixer`
  coupling rather than preserving it out of inertia.
- Independent receive buffers: voice keeps the existing low-latency adaptive
  jitter philosophy + FEC/concealment + reconnect reset; media may hold more
  latency (bounded), handles loss/reorder without growing the voice buffer,
  exposes underrun/trim/overflow separately. No shared expected-sequence map
  or buffer target.
- Voice-first send scheduling/backpressure: voice/control/presence never
  queue behind media backlog; media queue bounded; stale media frames dropped
  rather than accumulating latency; on would-block/congestion, shed media
  before voice; no indefinite retry of stale real-time media; preserve
  current UDP recovery semantics. A simple bounded priority scheduler beats a
  general-purpose queue framework.
- Protect control traffic (presence/ping-pong/recovery/capability packets)
  from media bandwidth starvation causing false reconnects — add explicit
  tests/diagnostics for this.
- Define per-transport behavior (Wi-Fi/shared LAN, local-only hotspot,
  Bluetooth Classic/RFCOMM, guest/WebRTC if applicable): constrained
  transports may negotiate lower/disabled media while keeping voice, but
  media must never destabilize voice for feature parity's sake.
- Audit lifecycle ownership across `WalkieTalkieCubit`/`AudioEngine`/
  `TransferRepository`; extract narrow components (voice sender/controller,
  media sender/controller, stream scheduler/QoS arbiter, per-stream receive
  buffer) — bounded extraction, not a broad rewrite.
- Extend `.tarklog` with bounded/rate-limited per-stream telemetry: profile/
  rate/bitrate per stream, packets/bytes, loss/gaps/late drops, queue depth,
  dropped-stale-media count, underruns, QoS/backpressure actions,
  control-plane health while media is active.

Safety invariants: voice survives media failure; stopping music never
restarts voice; muting voice doesn't stop music unless the user stops it;
starting music never forces a reconnect; media backlog never becomes
unbounded latency/memory; no isolate/task outlives its owning session; #26
screen-off/auto-recovery preserved.

Required tests include a deterministic stress/replay fixture: simultaneous
synthetic voice+media for a meaningful duration with injected jitter/loss/
backpressure, proving bounded queues and voice priority — plus independent
sequence spaces, media-throws-doesn't-affect-voice, media survives self-mute/
VOX silence, voice bypasses saturated media queue, control not starved,
independent jitter targets, clean reconnect recovery for both streams, no
leaks on repeated media stop/start, constrained-transport fallback, and
mixed-version peer fallback to legacy single-stream behavior.

Non-goals: ducking UX/gain policy (#31), final adaptive bitrate state machine
(#32), unrelated UI polish, cloud relay/music service integration.

Acceptance: separate logical streams with separate sequence/codec/buffer
state; media no longer clocked by mic callbacks; voice/control has explicit
priority under congestion; media queue bounded with stale-drop; one stream's
failure can't tear down the other; diagnostics/tests distinguish the two;
mixed-version and constrained-transport fallbacks defined and tested; #26
remains the merge gate.

---

## 6/8 — [#31] Add optional Smart Music Ducking

**Depends on #30, #29.** Desired flow: `music at user volume → speech begins
→ music smoothly ducks → speech stays clear → speech ends → music smoothly
returns`. **Must be fully optional** — a persisted Settings toggle
(`smartMusicDuckingEnabled`, default **enabled** for new installs) that,
when off, leaves shared-music gain completely unchanged. Toggle works
mid-session without reconnecting the channel; no attack/release/DSP jargon
exposed to users.

- Duck as close to final local playback as practical; never permanently alter
  the encoded media stream because one listener is talking.
- Voice-activity semantics: duck on real voice activity (remote peer
  speaking, local VOX gate open, overlapping speakers) rather than solely UI
  roster state; short hangover to prevent bounce between words; stay ducked
  while any relevant speaker is active; release smoothly when activity ends.
- Deterministic, centralized, unit-testable gain-envelope component (not
  scattered widget/cubit timer logic). Starting targets (validate by
  listening): duck to ~25–35% of user's music level, attack ~80–150 ms,
  release ~500–1000 ms after hangover, no clicks/discontinuities, no
  frame-rate dependency. User's chosen music gain stays the base — ducking is
  a temporary multiplicative envelope on top of it.
- Mixing: bounded gain/mix logic, no unchecked summation clipping, no voice
  DSP applied to music, ducking never changes network bitrate/profile or
  voice latency by itself; deterministic mono downmix if the output route is
  mono.
- Lifecycle: music stop clears ducking cleanly; voice disconnect/reconnect
  never leaves music stuck ducked; envelope survives background/screen-off or
  re-enters a safe state on resume; toggling off while ducked returns to
  normal gain without a channel restart; toggling on mid-speech enters the
  ducked state glitch-free.
- Rate-limited, privacy-safe diagnostics: enabled/disabled at session start,
  `normal→ducked→normal` transitions (no per-frame spam), optional
  reason/source class.
- Settings UI: simple toggle, e.g. title "Smart music ducking," subtitle
  "Automatically lowers shared music while someone is talking," standard
  switch, accessible label, no technical terms, localized to current app
  languages, single settings source of truth if an in-channel sheet mirrors it.

Non-goals: speech recognition, AI conversation detection, auto-pausing the
source app, changing media bitrate on speech (that's #32), user-facing
attack/release sliders.

Acceptance: ducks automatically when enabled; returns to exact user base gain
after speech; persisted toggle fully disables it; toggle works mid-session
without reconnect; overlapping speakers don't cause pumping/premature
release; no click/clip/NaN/unbounded gain; no effect on voice latency/
transport/codec; reconnect/media-stop can't leave music stuck ducked; tests
cover enabled/disabled/transition; physical motorcycle listening validation
recorded before final tuning is considered done.

---

## 7/8 — [#32] Split Voice/Media adaptive audio policy, graceful degradation

**Depends on #27, #28, #29, #30.** Today's single `OpusTuner` maps loss/RTT
to a speech-centric 12/16/20/24 kbps ladder and applies it to music too,
destroying music fidelity unnecessarily (~20 kbps music even on a ~48 kHz
capture path). Adaptation itself is proven valuable by the field data — it
must become stream-aware, not removed.

- Replace the one generic tuner with explicit, independently testable policy
  objects (architecturally: `VoiceQualityController`/`VoiceOpusTuner` and
  `MediaQualityController`/`MediaOpusTuner`), sharing signal-processing code
  where sensible but keeping product decisions independent.
- Preserve the existing rule: tune the sender from evidence about its own
  packets' direction (far-end loss, RTT/queueing delay, blocked sends,
  send-path failures, #30's media-scheduler drops/backpressure, transport
  type) — never build a feedback loop where both ends overreact to each
  other's unrelated receive state.
- Fast bitrate/complexity/FEC adaptation; slow, hysteresis-gated
  sample-rate/channel/profile transitions (minimum dwell time, only at a safe
  frame/session boundary, explicit decoder/jitter reset, logged transition +
  reason) — never flap 24↔16 kHz or stereo↔mono every few seconds.
- Voice policy: strong link prefers 24 kHz HD at an evidence-based bitrate;
  moderate loss holds 24 kHz while adjusting bitrate/FEC/complexity; sustained
  poor link allows deliberate fallback to 16 kHz; recovery upgrades only after
  a sustained clean period. Never reduce voice below the current usable floor
  to protect music.
- Media policy from #29's tiers (illustrative): ~96 kbps high, ~64 kbps
  normal HD, ~48 kbps constrained, ~32 kbps survival — exact thresholds
  justified by packet size/RF/CPU/listening evidence, never call 12–20 kbps
  "HD." If the link can't sustain acceptable media, prefer graceful media
  degradation/pause over harming voice; reduce media before it can pressure
  voice/control.
- Transport-aware ceilings/floors per mode (Wi-Fi/LAN, local hotspot, BT
  Classic/RFCOMM, guest/WebRTC) — a Wi-Fi-appropriate bitrate is not safe on
  RFCOMM.
- Small deterministic state machine for expensive tier transitions: current
  tier, downgrade evidence window, upgrade clean window, minimum
  dwell/cooldown, explicit transition reason. Downgrades faster than
  upgrades. Keep policy pure/testable with injected time/conditions rather
  than timer-heavy widget logic.
- Integrate with #30's scheduler: reserve voice+control budget first, media
  gets the remainder, media congestion resolved by dropping/reducing media
  alone whenever that's sufficient (no voice bitrate cuts for a media-only
  problem), expose when media is being throttled to protect voice.
- `.tarklog` diagnostics per transition: stream, previous→next tier/profile,
  bitrate/complexity/FEC, rate/channels on profile change, measured loss/RTT/
  backpressure inputs, reason, time-in-tier, upgrade/downgrade counts, media
  drops performed to protect voice — rate-limited, no per-packet private
  identifiers. #26's analyzer should be able to summarize time-per-tier.

Required tests use deterministic condition sequences (not real timers):
clean-link selects HD voice+media independently; moderate loss changes media
without needlessly lowering voice; heavy media backpressure reduces media
before voice; sustained poor voice link triggers fallback; a brief RTT spike
doesn't cause persistent flapping; upgrade requires sustained clean evidence;
cooldown behavior; 24k→16k transition resets codec/jitter state exactly once;
media stereo/mono/profile transitions bounded; constrained transport caps
media; unknown metrics handled conservatively; reconnect starts from a
defined safe state; #27's counter-reset/generation semantics can't produce
bogus tier changes; deterministic replay of identical conditions yields
identical transitions. Add a stress/replay fixture modeling realistic
motorcycle conditions (low baseline RTT/loss, short bursts, an RTT spike,
recovery, concurrent media pressure).

Performance: policy evaluation cheap relative to audio callbacks, no
per-frame heavy allocation, no rebuilding encoders every tick, bounded metric
history, no network polling/server dependency.

Non-goals: user-facing manual bitrate/sample-rate controls, ducking gain
behavior (#31), full transport rewrite, ML network prediction.

Acceptance: voice and media use separate adaptive policies; strong links use
the #28/#29 HD profiles; media degrades before it can harm voice/control;
expensive transitions have deterministic hysteresis and don't flap; sustained
bad links fall back without disconnecting; recovery upgrades only after
sustained clean evidence; every tier transition is explainable from measured
inputs in diagnostics; deterministic replay/stress tests cover realistic
conditions; #26 reliability and latency remain hard regression gates.

---

## 8/8 — [#33] Add a fast pre-ride audio/network Preflight

**Depends on #26 (baseline/diagnostics) and the final capability model from
#27–#30.** Goal: a fast (~1–few seconds on the happy path), automatic,
actionable, non-distracting pre-ride check that answers **"Ready to ride"**
or gives one-tap fixes — run before the phone goes in a pocket, not
discovered mid-ride. No fake green: a permission flag or "engine started"
boolean isn't enough when Tark can prove real signal/route/peer behavior.

Typed check result model: `pass` / `warning` / `fail` /
`unsupported·notApplicable`, each with a stable check code, severity,
localized summary, optional safe technical detail, optional remediation
action — no readiness logic derived from booleans scattered across widgets.

Required checks:
1. **Microphone** — verify permission *and* that real audio frames actually
   arrive within a bounded window (not just permission/started state); record
   negotiated capture rate/route for diagnostics; reuse existing mic-health/
   watchdog concepts.
2. **Playback/output route** — detect BT communication headset / wired-USB /
   built-in speaker/earpiece / unknown. Helmet/headset is the preferred
   result for riding; built-in speaker is a warning with "Continue anyway,"
   not a universal hard block (desk/dev use still needs to work). Don't treat
   A2DP presence as proof the communication mic route works — respect
   Android's communication-device semantics and `VoiceAudioSession`'s actual
   chosen route.
3. **Audio profile/capability readiness** (post #28/#29) — show simple
   `HD Voice ready` / `Standard voice`, verify local profile coherence and,
   if a peer is already known, the negotiated mutual profile; unsupported HD
   is never a failure if standard voice works.
4. **Network/transport readiness** — usable local network path, hotspot host/
   join state, BT connection state when selected by the transport advisor,
   socket/link health, no known terminal recovery state; use the automatic
   transport advisor rather than making the user pick manually. Separate
   "local transport ready" from "peer verified" since Preflight may run
   before join.
5. **Peer reachability/bidirectional audibility** (once connected) — bounded
   lightweight handshake reusing existing `heardIds`/audibility/send-path
   repair concepts; answer "can we hear them" and "can they hear us"
   separately. Never send recorded speech as a test packet — presence/control
   evidence is sufficient for transport reachability, real mic frames are
   verified locally in check 1.
6. **Background execution readiness** — foreground-service capability/state,
   required notification permission by Android version, battery-optimization/
   background-restriction posture where detectable, wake/Wi-Fi lock
   readiness, OEM-specific guidance only with real evidence. Never
   permanently block on an OS setting the app can't reliably determine — warn
   + one-tap settings navigation.
7. **Shared Music capability** (optional) — verify playback-capture
   capability, surface projection permission only when the user intends to
   use it, detect known unsupported platforms/OEMs where possible. Must never
   fail voice Preflight.
8. **Diagnostics readiness** — confirm logging/export works and the session
   can record negotiated route/profile/recovery evidence for field support,
   without exposing raw IP/device identifiers in the UI.

UX: compact sheet — Headset / Microphone / Connection / Background mode /
HD Voice / Shared Music, each Ready/Warning/etc., primary action "Start ride /
Enter channel." Failure examples map to one-tap fixes (Allow microphone,
Check headset, Open Wi-Fi settings, Fix background settings). No
developer-dashboard look.

Blocking policy (explicit in code + tests): hard failures are denied mic
permission (when voice required), no usable capture path, required transport
can't start, unrecoverable local init failure. Warnings/continue-allowed: no
helmet headset, HD unavailable but standard works, non-ideal battery
optimization with foreground service still viable, Shared Music unavailable,
peer not yet present in create/waiting state.

Lifecycle: no duplicate audio-engine ownership; no probe session left running
behind the real channel; deliberate warm-state reuse if safe; Back/Cancel
cleans up everything; repeated runs don't leak subscriptions/timers/platform
sessions; quick-access/home-widget entry paths stay consistent.

Tests: all-green path; mic permission denied; engine-started-but-no-frames;
BT headset vs phone-speaker warning; no network/local address; transport
initializing/recovering/down; peer present but outgoing audibility
unconfirmed; standard voice usable while HD unsupported; Shared Music
unsupported doesn't block voice; background-restriction warning; remediation
updates check state; cancel/retry leaks nothing; accessibility/RTL/
localization; quick-access/direct-channel flow. Physical validation required
(not fabricated in CI): one Samsung device, one Xiaomi/MIUI-class device if
available, real BT/helmet headset, screen-off transition after a green
Preflight.

Non-goals: full headset self-test/record-playback diagnostic (later task),
user-facing network engineering detail, forcing HD/Shared Music availability,
new backend, safety prompts while riding.

Acceptance: clear "Ready to ride" reachable without understanding internals;
mic readiness based on real frame delivery; actual output route classified
and inappropriate phone-route surfaced; local transport and peer reachability
checked separately; HD-unavailable-but-standard-works treated as usable;
Shared Music optional and non-blocking; background restrictions produce
actionable warnings; blocking-vs-warning policy explicit and unit-tested; no
leaked resources; UI simple/localized/accessible; physical field validation
required before declaring this complete.
