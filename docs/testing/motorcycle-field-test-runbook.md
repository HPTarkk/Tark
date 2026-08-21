# Motorcycle field-test runbook

Tracks GitHub issue [#26](https://github.com/HPTarkk/Tark/issues/26), phase
1/8 of [ROADMAP.md](../../ROADMAP.md). This is the reproducible verification
workflow for the one behavior that matters most on a ride:

> Connect two phones, put them in your pockets, ride for an hour, and never
> have to pull the phone out to touch the app.

Confirmed working in the 2026-08-19 two-device rider/pillion field test. The
next seven roadmap issues change the audio stack substantially (HD voice, HD
music, independent streams, adaptive QoS) — this runbook is what protects the
behavior below from silently regressing while that happens.

## What "automatable" and "physical-device-only" mean here

Every item below is one or the other, never both:

- **Automatable** — has a real `flutter test` (or `python` test) file that
  exercises the underlying logic without hardware. Pointed to by file path.
  Run before every merge that touches the areas in scope.
- **Physical-device-only** — genuinely needs two real phones, real radios,
  and a real ride (or a driveway/parking-lot stand-in). **Never claimed by
  CI.** There is no CI wired up in this repo right now
  (`.github/workflows/flutter-build.yml` is fully disabled) and this runbook
  doesn't change that — these checks are owner/field evidence, recorded here
  as done or not done, not as a pass/fail automated gate.

## Privacy — read before exporting anything

**Never commit a raw `.tarklog` export, or any text copied out of one, to
this repository or to an issue/PR.** A log can contain device identifiers,
peer identifiers, IP addresses, SSIDs, and display names. When recording
field-test evidence here or in an issue, use only the aggregate, privacy-safe
summary that `scripts/decode_tark_log.py --report` prints — never the raw
export, and never a screenshot of one.

## Setup

- Two Android phones running the same build.
- Real Bluetooth/helmet headsets on both (not phone speakers — that changes
  the audio-route behavior being tested).
- Rider + pillion, or two riders on separate bikes within range.
- Wi-Fi/hotspot transport (the automatic transport advisor's default path).

## Checklist

### Connection and recovery

- [ ] **Automatable** — session-epoch bookkeeping rejects stale/ghost traffic
  and accepts an immediate rejoin without a grace-period penalty:
  `test/session_epoch_gate_test.dart`.
- [ ] **Automatable** — the hotspot link keeper rebinds sockets (not a full
  rejoin) when the OS moves this device back onto the AP after a screen-off
  nap, and re-hosts when the AP itself is torn down mid-session:
  `test/hotspot_link_keeper_test.dart`.
- [ ] **Automatable** — the recovery ladder escalates
  `degraded → reconnecting → renegotiating` and never reports a terminal
  `down` state on its own: `test/recovery_ladder_test.dart`.
- [ ] **Physical** — a transient network/hotspot disturbance (walk out of
  range and back, toggle airplane mode briefly, move between AP and phone
  data) recovers automatically. No manual leave/rejoin.
- [ ] **Physical** — leave/rejoin sanity check: leaving and rejoining the same
  channel code works cleanly on both ends.
- [ ] **Physical** — headset disconnect/reconnect during a live session does
  not require restarting the app.

### Screen-off / background

- [ ] **Automatable** — a screen-off nap (verified against the real gaps seen
  in the field logs: 4.8s, 16.6s, 31.2s, 33.7s) does not trigger a false
  "mic restart" — the stall watchdog credits time the isolate was suspended
  rather than reading it as silence: `test/stall_watchdog_test.dart`. This
  is the automated regression test for the false-mic-restart-on-resume gap
  the issue named; see also
  `lib/feature/audio/domain/stall_watchdog.dart`'s doc comment.
- [ ] **Documented gap, not automated** — music-cast capture must not be torn
  down by backgrounding. Traced in code: `WalkieTalkieCubit`'s
  `didChangeAppLifecycleState` only clears the stale queued-audio backlog on
  resume (`_musicMixer.clear()`), it never cancels or recreates the capture
  subscription — see the comment at that call site. Proving this with an
  automated test would need either a full `WalkieTalkieCubit` test harness
  (13 constructor dependencies, none of which have fakes in this repo today)
  or platform-channel mocking for the static `SystemAudioCapture.frames`
  `EventChannel` — both a meaningfully bigger investment than this issue's
  scope. Verify physically instead.
- [ ] **Physical** — put both phones in pockets, screen off, for at least 10
  continuous minutes during active conversation + shared music. No dropouts,
  no permanent one-way audio, no unexpected mic-restart banner on resume.

### Audio continuity

- [ ] **Automatable** — `AudioPlaybackBuffer.reset()` (what a genuine
  reconnect calls) clears per-sender sequence/stats state so the first
  packet of a reconnected stream plays immediately, unlike the slower
  in-stream restart heuristic that needs many packets to trust a far-behind
  sequence: `test/audio_playback_buffer_test.dart` (`reset() after a real
  reconnect` group).
- [ ] **Automatable** — the adaptive jitter-depth controller preserves what
  the link already taught it across a `reset()`, rather than re-learning
  from scratch on every reconnect: `test/audio_playback_buffer_adaptive_test.dart`.
- [ ] **Automatable** — no duplicate subscriptions/timers survive a retry:
  `WalkieTalkieCubit.retryStart()` disposes its full resource set through
  `DisposeBag` before re-wiring, and re-registering under an existing key
  cancels the stale entry: `test/dispose_bag_test.dart`.
- [ ] **Physical** — continuous conversation over the whole ride, VOX behaving
  normally (opens on speech, closes on silence, no chatter).
- [ ] **Physical** — shared music/podcast runs for a long continuous interval
  on the sender without a MusicMixer dropout or a user-visible channel
  disconnect.

### Diagnostics

- [ ] **Automatable** — the container format's cross-language keystream
  matches between the Dart encoder and `scripts/decode_tark_log.py`, gzip +
  CRC32 round-trips, and no plaintext survives outside the keystream:
  `test/tark_log_format_test.dart`.
- [ ] **Automatable** — the diagnostic log ring stays under its byte ceiling,
  keeps newest lines in order across segments, and resumes correctly across
  detach/attach cycles: `test/diagnostic_log_rotation_test.dart`.
- [ ] **Automatable** — `scripts/decode_tark_log.py --report` scopes its
  metrics to one selected session and never merges two `--- session ...
  opened` blocks from a multi-run ring log: `scripts/test_decode_tark_log.py`.
- [ ] **Physical** — diagnostic export completes on both phones at the end of
  the ride, and `python scripts/decode_tark_log.py --report <file>` produces
  a sane privacy-safe summary (see below).

## Reading a field export

```bash
python scripts/decode_tark_log.py tark-log-YYYYMMDD-HHMMSS.tarklog --report
```

Prints, for the selected session (defaults to the most recent `--- session
... opened` block; pass `--session N` to pick another): duration, negotiated
capture/playback/wire sample rates, RTT and loss summary, reconnect/rebind/
recovery event counts, codec-profile transitions, jitter-buffer underrun/
resync/concealment counts, MusicMixer dropout/trim/flood/overflow counts,
background/resume events, and terminal-failure lines. No IPs, SSIDs, device
identifiers or names — only what the existing diagnostic log lines already
carry.

## Field acceptance gates

These protect *today's* proven behavior as a regression gate for the HD-audio
workstream (issues 3–7 of the roadmap). They are deliberately about
protecting what already works, not a universal SLO derived from one day's RF
conditions:

- No manual leave/rejoin should be required for a transient, recoverable
  link event.
- No permanent one-way audio after a recovery.
- Background/screen-off operation must remain alive for the physical ride
  test — this is the app's whole reason to exist.
- Shared music must not cause a channel disconnect.
- No unbounded queue growth, runaway memory, or a recovery loop that never
  settles.
- No regression in perceived conversation latency relative to this baseline
  build.

Any change to the audio stack (issues 3–7) that regresses one of these gates
blocks the merge, regardless of how much fidelity it buys.
