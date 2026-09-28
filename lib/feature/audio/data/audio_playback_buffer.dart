import 'dart:async';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';

import '../../../core/utils/logger.dart';
import '../domain/float64_fifo.dart';

/// Jitter buffer that smooths bursty UDP/Bluetooth audio delivery before
/// playback.
///
/// Packets arrive in uneven bursts, can be lost, and can arrive out of order.
/// Writing them directly to the audio output causes glitches (underruns
/// between bursts, overruns on arrival, and — without sequence tracking —
/// jumbled/discontinuous speech when packets are lost or reordered). This
/// buffer accumulates samples until [targetBufferMs] worth have arrived, then
/// drains them at a steady [drainIntervalMs] rate via a periodic timer. Lost
/// packets (detected via sequence number gaps) are concealed with silence
/// rather than silently skipped, which keeps audio timing intact instead of
/// producing a "fast forward" jumble.
///
/// Sequence tracking is kept per sender: a WiFi channel can have more than
/// one other participant, and each sender has its own independent sequence
/// counter. Tracking a single shared "expected sequence" across senders
/// meant that once any one sender's stream advanced it, every other
/// sender's (lower-numbered) packets would permanently fail the stale-packet
/// check below and get silently dropped for the rest of the session.
///
/// ## Do not change the drain cadence
///
/// The drain pushes **whole [_drainSize] slices**, never a variable,
/// wall-clock-sized amount. Replacing it with an elapsed-wall-clock drain
/// (variable samples per tick, matching real time) was tried and produced
/// badly chopped audio on Bluetooth, repeatedly, across several tunings of
/// depth and thresholds.
///
/// What decides how many slices a tick pushes is the device itself: where the
/// platform reports how much is still unplayed in the native ring
/// ([outputQueuedFrames], Android), each tick tops the ring back up to its
/// cushion. Elsewhere a tick pushes one slice per timer period that has
/// passed, including periods the timer skipped. It used to be exactly one
/// slice per callback, but Dart does not replay a periodic timer's missed
/// ticks: a callback more than one period late skips the missed ones. Every
/// UI hiccup over 10 ms therefore took 10 ms out of the device's cushion for
/// good, so after a few of them the device ran dry every few seconds and
/// filled the gap with zeros, heard as a faint recurring tick. The same
/// missing slices let the feed outrun the drain, which is what kept the
/// queue near twice its target, trimming, and added delay.
///
/// Latency is therefore bounded WITHOUT touching the cadence: stale audio is
/// trimmed from the head of the queue (see [_trimStep]). That changes what
/// is pushed, never how fast, so it cannot starve or overrun the downstream
/// native ring.
///
/// The adaptive depth below obeys the same rule. It moves [_targetSamples] —
/// how much is accumulated before playback starts and what the trim walks back
/// down to — and never [_drainSize] or [_drainIntervalMs]. Everything the
/// paragraph above warns about stays exactly as it was.
///
/// ## The depth adapts, the cadence does not
///
/// A fixed depth is wrong in both directions: 100 ms is needless delay for two
/// phones on one desk, and too shallow for a hotspot between two moving bikes.
/// So the target tracks the link between [_minTargetSamples] and
/// [_maxTargetSamples], growing the moment the queue runs dry and shrinking
/// only after a sustained calm stretch. See the adaptation section for why
/// those two directions are deliberately not symmetric.
///
/// ## Where playback latency actually lives
///
/// End-to-end delay is this queue plus the native output ring downstream
/// (`audio_io_miniaudio.cpp`, 8192 samples). That ring is drained by the audio
/// hardware at exactly real time and **silently discards** whatever doesn't
/// fit on write, so it cannot itself hold seconds of audio — which is why a
/// multi-second delay could only ever have come from this queue.
///
/// ## Why the native ring is deliberately kept non-empty
///
/// The drain pushes one fixed slice per tick and the device consumes at
/// exactly real time, so left alone the native ring holds one slice right
/// after a tick and *nothing* just before the next — a mean cushion of half a
/// tick and a worst case of zero. A late timer (routine on the UI isolate: one
/// dropped frame is already 16.7 ms) then leaves the playback callback with no
/// data, and it fills the gap with zeros. Those steps to silence and back are
/// audible as a faint recurring tick, independent of transport. [_prefillSamples]
/// gives the ring a head start so ordinary jitter cannot empty it; it offsets
/// where the ring sits between ticks and does not touch the cadence.
///
/// ## Native playout (Android)
///
/// Where the platform has a native voice queue ([VoiceQueue], miniaudio's
/// playback callback), none of the timer machinery above runs. Samples go
/// straight into that queue and the device pulls them itself, so there is no
/// Dart timer to fall behind and no cushion to size. This class then keeps
/// only what needs no clock: packet order, loss concealment, and the adaptive
/// depth, which it pushes to the native side. Starting, trimming, the jump
/// back to live and running dry are decided in the callback
/// (`packages/audio_io/src/voice_playout.h`). The timer path stays for iOS,
/// where playback goes through AVAudioEngine instead.
class AudioPlaybackBuffer {
  AudioPlaybackBuffer({
    required Sink<List<double>> output,
    int sampleRate = 48000,
    int targetBufferMs = 100,
    int drainIntervalMs = 10,
    int outputPrefillMs = kDefaultOutputPrefillMs,
    this.adaptive = true,
    this.debugLogging = false,
    int Function()? outputUnderrunFrames,
    int Function()? outputQueuedFrames,
    VoiceQueue? voiceQueue,
  }) : _output = output,
       _native = voiceQueue,
       _sampleRate = sampleRate,
       _targetSamples = sampleRate * targetBufferMs ~/ 1000,
       _minTargetSamples =
           (sampleRate * targetBufferMs * _kMinTargetRatio ~/ 1000).round(),
       _maxTargetSamples =
           (sampleRate * targetBufferMs * _kMaxTargetRatio ~/ 1000).round(),
       _drainSize = sampleRate * drainIntervalMs ~/ 1000,
       _drainIntervalMs = drainIntervalMs,
       _defaultChunkLen = sampleRate * 10 ~/ 1000,
       _prefillSamples = sampleRate * outputPrefillMs ~/ 1000,
       _outputUnderrunFrames = outputUnderrunFrames,
       _outputQueuedFrames = outputQueuedFrames {
    final native = _native;
    if (native != null) {
      native.targetFrames = _targetSamples;
      _lastNative = _NativeCounters.read(native);
      _nativeTimer = Timer.periodic(
        const Duration(milliseconds: _nativeTickMs),
        (_) => _nativeTick(),
      );
    }
  }

  // ── Native playout ─────────────────────────────────────────────────────

  final VoiceQueue? _native;

  /// Housekeeping only: adaptation, the health log, and pushing the depth.
  /// Nothing audible depends on when this runs.
  Timer? _nativeTimer;
  static const int _nativeTickMs = 50;
  int _nativeTicks = 0;
  _NativeCounters? _lastNative;

  /// The last few milliseconds of the newest packet, held back from the
  /// native queue. Once samples are there they belong to the audio thread,
  /// so a loss can no longer ramp down the audio in front of it; holding
  /// this much back is what lets [_enqueueSilence] still fade into the gap.
  /// Costs [_spliceFadeSamples] of delay.
  Float64List _heldTail = Float64List(0);

  /// Native ticks since a packet last arrived, so a tail left over at the
  /// end of a talk burst is not glued onto the front of the next one.
  /// Counted in ticks rather than wall time so it follows the same clock as
  /// everything else here. Three ticks is 100-150 ms: past normal jitter.
  int _ticksSinceFeed = 0;
  static const int _staleTailTicks = 3;

  /// How far below and above the configured depth adaptation may travel.
  ///
  /// Anchored to the user's setting rather than fixed in milliseconds, so the
  /// setting keeps meaning "how much buffer I want" — now as the centre of a
  /// range instead of a fixed point. At the default 100 ms this lands exactly
  /// on the roadmap's band: 60 ms for close WiFi, ~100 for a hotspot, 180 for a
  /// weak link. Someone who raises the slider to 300 because their link is
  /// genuinely awful gets the whole range raised with it, rather than having
  /// adaptation quietly overrule them back down to 180.
  static const double _kMinTargetRatio = 0.6;
  static const double _kMaxTargetRatio = 1.8;

  /// Head start handed to the native output ring whenever playback starts.
  ///
  /// Sized to absorb a couple of dropped UI frames, which is the realistic
  /// worst case for a `Timer.periodic` sharing an isolate with rendering.
  /// Costs this many milliseconds of one-off latency; lower it only with the
  /// underrun counter in the debug log as evidence that the smaller cushion
  /// still holds.
  static const int kDefaultOutputPrefillMs = 30;

  final Sink<List<double>> _output;
  final int _prefillSamples;

  /// Reads the native playback underrun counter for the debug log, so the
  /// cushion above can be judged against a real measurement from a device
  /// rather than another theory.
  final int Function()? _outputUnderrunFrames;

  /// Samples in the native output ring the device has not played yet, or a
  /// negative number where the platform cannot tell. When known, each tick
  /// writes as many slices as it takes to bring the ring back to
  /// [_prefillSamples] plus the most the device has been seen to take
  /// between two ticks, so the drain follows the device's own clock and a
  /// late tick is made good on the next one.
  final int Function()? _outputQueuedFrames;

  /// Upper bound on slices per tick, whichever way the count is decided. A
  /// tick that finds the device far behind (a long isolate pause) must not
  /// dump the whole queue into the native ring in one go. Sized to refill
  /// the largest cushion ([kMaxOutputCushionMs]) in one tick.
  static const int _maxSlicesPerTick = 16;

  /// Ceiling on the native ring cushion, kept well inside the 8192-sample
  /// native ring (170 ms at 48 kHz).
  static const int kMaxOutputCushionMs = 150;
  late final int _maxCushionSamples = _sampleRate * kMaxOutputCushionMs ~/ 1000;

  // ── Device burst size ──────────────────────────────────────────────────
  //
  // Most phones pull a few milliseconds from the ring at a time, so a cushion
  // of [_prefillSamples] plus one slice keeps them fed. Not all: a Galaxy S8+
  // on Android 9 pulls ~100 ms in one go (its capture log shows ten mic
  // callbacks a second). Topping its ring up to 40 ms meant each pull found
  // 40 ms and played 60 ms of zeros, so only 40% of the voice reached the
  // speaker, the queue overflowed, and the jump-to-live cut the rest: robotic
  // voice for the whole call. So the cushion is measured, not assumed: the
  // most the ring lost between two ticks over the last second or so is what
  // the device can take at once, and the ring is kept that much fuller.

  /// Ring level right after the previous tick's writes, or -1 when unknown.
  int _levelAfterLastTick = -1;

  /// Largest drop between two ticks, in this window and the one before, so
  /// the estimate always covers at least one full window of evidence.
  int _burstThisWindow = 0;
  int _burstLastWindow = 0;
  int _burstWindowTicks = 0;
  static const int _burstWindowLength = 50;

  /// What the device can take in one pull, as far as the ring has seen.
  /// Exposed for tests and the health log.
  int get deviceBurstSamples {
    final native = _native;
    if (native != null) return native.deviceBurstFrames;
    final seen = _burstThisWindow > _burstLastWindow
        ? _burstThisWindow
        : _burstLastWindow;
    return seen > _drainSize ? seen : _drainSize;
  }

  /// [Timer.tick] at the previous drain callback, for platforms that fall back
  /// to counting timer periods.
  int _lastDrainTick = 0;
  final int _sampleRate;

  /// Depth the buffer fills to before playing, and walks back down to when it
  /// overruns. Mutable: see the adaptation section below.
  int _targetSamples;
  final int _minTargetSamples;
  final int _maxTargetSamples;
  final int _drainSize;
  final int _drainIntervalMs;
  final int _defaultChunkLen;

  /// Whether [_targetSamples] tracks the link. Off only in tests that need a
  /// pinned depth to assert against.
  final bool adaptive;

  /// Periodically logs queue depth and event counters. Left in deliberately:
  /// this bug was chased through several wrong theories for want of a single
  /// real measurement from a device.
  final bool debugLogging;

  // Unboxed ring buffer: a Queue<double> here boxed every received sample
  // and unboxed it again on drain — tens of thousands of heap allocations
  // per second of playback, enough GC pressure to pause the UI isolate.
  final Float64Fifo _queue = Float64Fifo(8192);
  Timer? _drainTimer;
  bool _filling = true;

  /// Hard cap, scaled to this instance's actual sample rate (previously a
  /// hardcoded 48 kHz sample count — at a 16 kHz output rate, as commonly
  /// negotiated over Bluetooth SCO/HFP, that made the real cap 3x longer in
  /// time than intended). This is only a memory backstop; [_trimStep]
  /// bounds latency well before this.
  static const int kMaxQueueMs = 1000;
  late final int _maxQueueSamples = _sampleRate * kMaxQueueMs ~/ 1000;

  /// Depth above which the queue is considered to be holding stale audio.
  /// Must be above target: Bluetooth delivery is bursty and the queue
  /// routinely spikes for a moment. A getter rather than a cached value because
  /// [_targetSamples] moves — a threshold left behind at a stale target would
  /// trim against a depth the buffer is no longer aiming for.
  int get _trimThreshold => _targetSamples * 2;

  /// Backlog past which the buffer stops walking latency down and jumps
  /// straight back to target in one crossfaded cut.
  ///
  /// The gentle trim below gives back 10 ms every 200 ms: fine for the few
  /// tens of milliseconds a jittery link leaves behind, but a second of
  /// backlog (a Bluetooth link that stalled and then flushed) would take
  /// twenty seconds to walk off, and the whole conversation would lag for all
  /// of it. Past this point, skipping the late audio is the better trade, the
  /// way call apps do: a word may be lost, but the listener is live again at
  /// once.
  int get _jumpThreshold => _targetSamples + _jumpSlackSamples;
  late final int _jumpSlackSamples = _sampleRate * kJumpSlackMs ~/ 1000;

  /// How far past target the queue may run before [_jumpThreshold] applies.
  static const int kJumpSlackMs = 250;

  /// Latency is walked down in small steps rather than snapped back in one
  /// splice. A single trim big enough to cover the whole backlog removes an
  /// audible chunk of speech — a whole syllable. Dropping [_trimStepSamples]
  /// (10 ms, softened by the fade ramp) every [_trimIntervalTicks] is
  /// perceptually close to invisible and reaches the same place within a few
  /// seconds.
  late final int _trimStepSamples = _sampleRate * 10 ~/ 1000;
  late final int _trimIntervalTicks = (200 / _drainIntervalMs).ceil();
  int _sinceTrimTicks = 0;

  // ── Adaptive depth ─────────────────────────────────────────────────────
  //
  // The target was a fixed 100 ms, which is the wrong depth twice over: too
  // deep for two phones on the same desk, and too shallow for a hotspot at
  // speed. The two signals that say which way it is wrong are already measured
  // here — an underrun means the buffer ran dry and was too shallow, a late
  // drop means a packet arrived after its slot had already been played, which
  // is the same statement about jitter from the other side.
  //
  // ## Growing and shrinking are deliberately not symmetric
  //
  // Being too shallow is audible immediately: the drain stops, the ramp decays
  // to silence, and the listener hears speech chopped. Being too deep is a
  // slowly-annoying delay nobody notices in a sentence. So the buffer grows
  // **on the underrun itself** — not on the next window boundary — and shrinks
  // only after a sustained stretch with nothing wrong at all.
  //
  // Growing on the underrun rather than on a tick also avoids a trap: the drain
  // timer is cancelled while the queue refills, so a buffer that is underrunning
  // constantly barely advances its tick count, and a purely tick-driven
  // adaptation would grow slowest in exactly the conditions that need it most.

  /// How often the calm-weather half of adaptation is evaluated.
  static const int _adaptIntervalMs = 2000;
  late final int _adaptEveryTicks = (_adaptIntervalMs / _drainIntervalMs)
      .ceil();
  int _adaptTicks = 0;

  /// Consecutive clean windows before the depth is walked back down. Five
  /// windows is ten seconds — long enough that a lull between two bursts of
  /// jitter cannot be mistaken for a link that has genuinely improved.
  static const int _calmWindowsBeforeShrink = 5;
  int _calmWindows = 0;

  /// Late arrivals in the current window past which the depth grows. Not zero:
  /// a single straggler is ordinary UDP, and reacting to it would ratchet the
  /// depth up on a link that is behaving.
  static const int _lateDropsBeforeGrow = 3;
  int _lateDropsSinceAdapt = 0;

  /// Grown in bigger steps than it shrinks, for the reason above.
  late final int _growStepSamples = _sampleRate * 20 ~/ 1000;
  late final int _shrinkStepSamples = _sampleRate * 10 ~/ 1000;

  /// Beyond this many missing chunks in a row, treat it as a new talk burst
  /// (e.g. after a VOX silence) instead of filling a huge silence gap.
  static const int _maxConcealedGapChunks = 50;

  /// How far behind the expected sequence a packet may be and still be read as
  /// ordinary UDP reordering rather than the sender having restarted its
  /// counter. Real reordering is a handful of packets; a restart lands
  /// thousands behind, so anything in between is safely on either side.
  static const int _maxReorderChunks = 50;

  /// Consecutive packets a far-behind stream must deliver before it is accepted
  /// as the sender's restarted counter rather than a stale duplicate.
  ///
  /// A restart and a duplicate look identical in the first packet — both land
  /// far below [_expectedSeqBySender]. They differ in what happens next: after
  /// a real restart the old numbering never returns, whereas a second delivery
  /// path keeps interleaving packets from both. So the decision is deferred
  /// until the new numbering has proved it is the only one left.
  ///
  /// Ten chunks is ~200 ms. That is the one-off cost of a genuine restart (the
  /// old branch paid nothing but let duplicates through), and it is far longer
  /// than the alternation period of a duplicate path, which resets the
  /// candidate on every live packet and so can never accumulate it.
  static const int _restartConfirmChunks = 10;

  /// Minimum spacing between the "hearing a sender twice" diagnostics. The
  /// condition fires per packet — a line each would be ~150 a minute, which is
  /// how the original report arrived — so the log carries a rate and a lag
  /// instead of a transcript.
  static const Duration _duplicateLogInterval = Duration(seconds: 30);

  /// Same treatment for the resync line — see where it is emitted for why it
  /// cannot be one line per event.
  static const Duration _resyncLogInterval = Duration(seconds: 10);
  final Map<String, DateTime> _resyncLoggedAtBySender = {};

  /// Short ramp applied right after playback resumes (initial fill, after an
  /// underrun, or after a trim) to avoid an audible click at the
  /// silence→audio or splice boundary.
  late final int _fadeInSamples = (_sampleRate * 0.003).round().clamp(
    1,
    1 << 30,
  );
  int _fadeRemaining = 0;

  /// Length of the crossfade that joins the two sides of a trim, and of the
  /// ramps either side of concealed silence. Longer than [_fadeInSamples]:
  /// both sides are real audio here, and a few more milliseconds of overlap is
  /// what makes the join inaudible.
  late final int _spliceFadeSamples = (_sampleRate * 0.005).round().clamp(
    1,
    1 << 30,
  );

  /// Set when silence was just queued to cover lost packets, so the next
  /// packet ramps up out of it rather than stepping straight to full level.
  bool _fadeInNextFeed = false;

  /// Length of the synthesised decay pushed when the drain stops. Matches the
  /// fade-in so a stop/resume pair is symmetric.
  late final int _fadeOutSamples = _fadeInSamples;

  /// Last sample handed to the device, so an underrun that finds the queue
  /// empty on an exact slice boundary can still decay from the real level
  /// instead of stepping straight to silence.
  double _lastEmittedSample = 0.0;

  // Sequence tracking for loss/reorder detection, per sender id.
  final Map<String, int> _expectedSeqBySender = {};
  final Map<String, int> _lastChunkLenBySender = {};

  /// In-progress evidence that a sender's counter has restarted, per sender.
  /// Cleared the moment a packet arrives on the established numbering — that
  /// is the proof the far-behind stream was a duplicate, not a restart.
  final Map<String, _RestartCandidate> _restartCandidateBySender = {};

  /// Stale duplicates dropped per sender, and when we last said so.
  final Map<String, int> _duplicateDropsBySender = {};
  final Map<String, DateTime> _duplicateLoggedAtBySender = {};

  /// Everything that happened to each sender's stream since the last report.
  ///
  /// Per sender rather than global because the failures that matter here are
  /// per stream and cancel out when summed: one peer resyncing 300 times a
  /// minute while another plays perfectly is the exact shape of a split
  /// delivery route, and a single combined counter would show only "some
  /// resyncs" and lose which peer to look at.
  final Map<String, _SenderStats> _statsBySender = {};

  _SenderStats _stats(String senderId) =>
      _statsBySender[senderId] ??= _SenderStats();

  // Diagnostics. The per-window sample counters are the important ones: they
  // measure directly whether the feed outruns the fixed-cadence drain, and by
  // how much, which is the thing every theory about this bug has hinged on.
  int _underruns = 0;
  int _lastDeviceUnderrunFrames = 0;
  int _trims = 0;
  int _jumps = 0;
  int _overflowDrops = 0;
  int _fedWindow = 0;
  int _concealedWindow = 0;
  int _drainedWindow = 0;
  int _logTicks = 0;

  /// Reporting period for [_logHealth]. Fifteen seconds, matching the wifi
  /// transport's session line so the two can be read side by side against the
  /// same clock — that pairing is what turns "audio was bad here" into "and
  /// here is what the network was doing at that second". It was two seconds
  /// while this only went to a debug console; at that rate a persistent log
  /// would be nothing but this line.
  static const int _logIntervalMs = 15000;
  late final int _logEveryTicks = (_logIntervalMs / _drainIntervalMs).ceil();

  int _ms(int samples) => samples * 1000 ~/ _sampleRate;
  int get _queueMs => _ms(queuedSamples);

  /// Samples currently waiting to be played. Exposed for diagnostics and for
  /// tests that need to assert on concealment/drop decisions directly, rather
  /// than inferring them from what eventually reaches the device.
  int get queuedSamples {
    final native = _native;
    if (native != null) return native.queuedFrames + _heldTail.length;
    return _queue.length;
  }

  /// Whether the drain timer is currently running — i.e. whether this
  /// buffer's own write to [_output] is what's covering the current tick.
  /// #30's media mixing reads this: a second, independent timer writing to
  /// the same output sink would not *mix* with what this one writes, it
  /// would interleave two unrelated PCM streams (see
  /// `AudioEngineImpl`'s media coordinator for the full reasoning) — so
  /// media's own tick only writes directly when this is false.
  bool get isDraining => _native?.isPlaying ?? _drainTimer != null;

  /// Depth the buffer is currently aiming for, in milliseconds. Exposed so
  /// adaptation can be asserted on directly and read off the health log.
  int get targetBufferMs => _ms(_targetSamples);

  /// Grows the depth by one step, bounded. Called the moment the queue runs
  /// dry, which is the one signal that cannot wait for a window boundary.
  void _growTarget() {
    if (!adaptive) return;
    _calmWindows = 0;
    if (_targetSamples >= _maxTargetSamples) return;
    final grown = _targetSamples + _growStepSamples;
    _targetSamples = grown > _maxTargetSamples ? _maxTargetSamples : grown;
  }

  /// The calm-weather half: shrink after a sustained stretch with nothing
  /// wrong, and grow on sustained late arrivals even if the queue never
  /// actually ran dry.
  void _adaptStep() {
    if (!adaptive) return;
    if (_lateDropsSinceAdapt >= _lateDropsBeforeGrow) {
      _lateDropsSinceAdapt = 0;
      _growTarget();
      return;
    }
    _lateDropsSinceAdapt = 0;
    if (++_calmWindows < _calmWindowsBeforeShrink) return;
    _calmWindows = 0;
    if (_targetSamples <= _minTargetSamples) return;
    final shrunk = _targetSamples - _shrinkStepSamples;
    _targetSamples = shrunk < _minTargetSamples ? _minTargetSamples : shrunk;
  }

  /// Feed incoming samples into the buffer.
  ///
  /// [seq] is the sender's monotonically increasing packet counter, scoped
  /// to [senderId]. Gaps are concealed with silence so playback timing stays
  /// correct; packets that arrive late (seq below what's already been
  /// consumed for that sender) are dropped instead of being spliced in out
  /// of order.
  void feed(List<double> samples, int seq, String senderId) {
    final expectedSeq = _expectedSeqBySender[senderId];
    final lastChunkLen = _lastChunkLenBySender[senderId] ?? _defaultChunkLen;

    final stats = _stats(senderId);
    stats.packets++;

    if (expectedSeq == null) {
      // First packet from this sender — nothing to compare against yet.
    } else if (seq < expectedSeq) {
      final behind = expectedSeq - seq;
      if (behind <= _maxReorderChunks) {
        // Genuinely late — too old to splice back into sequence. Also the
        // gentler of the two signals that the depth is too shallow: this packet
        // would have played if the buffer had been holding a little more.
        stats.lateDrops++;
        _lateDropsSinceAdapt++;
        return;
      }
      // Miles behind. Two different things look exactly like this:
      //
      //  * the sender's counter restarted. A sequence counter lives on the
      //    transport repository and starts at zero — per repository, so
      //    switching transport restarts it — while the sender's identity does
      //    not change with it. Before identity was stable the same thing
      //    happened whenever hotspot DHCP recycled an address onto a different
      //    phone.
      //  * the same packet reached us a second time by another route. Phones
      //    here are routinely multi-homed (hotspot subnet, router subnet, a VPN
      //    tun) and audio goes out to every broadcast address we know, so a
      //    peer can be heard twice with the copies seconds apart.
      //
      // Telling them apart cannot be done from one packet, so it is done from
      // what follows: [_restartCandidate] accumulates consecutive far-behind
      // packets and only switches over once the old numbering has stayed gone
      // for [_restartConfirmChunks]. A duplicate path never gets there — every
      // live packet clears the candidate below.
      //
      // Until it is decided, the packet is dropped. Handing it to [_enqueue]
      // instead (which is what this branch used to do) is what put seconds-old
      // audio into the queue interleaved with live audio, at roughly twice the
      // drain rate, so [_dropOverflow] chopped the head continuously.
      //
      // The confirmation must stay bounded for the reason the old fallthrough
      // existed: the stale branch above returns WITHOUT advancing the expected
      // sequence, so a sender that is never resynced is silently muted for the
      // rest of the session, in one direction, with no way back short of
      // leaving the channel — which is precisely how it was reported.
      if (!_confirmsRestart(senderId, seq)) {
        _noteDuplicate(senderId, behind, lastChunkLen);
        return;
      }
      stats.resyncs++;
      _nativeDiscontinuity();
      // Rate-limited like the duplicate line below, and for the same reason:
      // when this fires it does not fire once. A stream split across two
      // delivery paths flips numbering every few hundred milliseconds, and a
      // line per flip buries every other category in the log — which is
      // exactly what a real capture of this bug looked like: thousands of
      // these, and no room left for anything that explained them.
      final now = DateTime.now();
      final lastAt = _resyncLoggedAtBySender[senderId];
      if (lastAt == null || now.difference(lastAt) >= _resyncLogInterval) {
        _resyncLoggedAtBySender[senderId] = now;
        Logger.diagnostic(
          'playback: sender $senderId restarted its sequence '
          '($expectedSeq -> $seq) — resyncing '
          '(${stats.resyncs} resyncs so far this window)',
        );
      }
    } else if (seq > expectedSeq) {
      final missing = seq - expectedSeq;
      if (missing <= _maxConcealedGapChunks) {
        stats.concealedChunks += missing;
        _enqueueSilence(missing * lastChunkLen);
      } else {
        // A large gap (new talk burst, or a stretch of loss too long to paper
        // over) resyncs without filling silence. Counted because the two are
        // very different symptoms: concealed chunks are heard as small holes,
        // while a jump here is heard as speech starting mid-word.
        stats.bigGaps++;
        _nativeDiscontinuity();
      }
    }

    // This packet is on the numbering we are playing, so any far-behind stream
    // still gathering evidence has just been contradicted: the counter it
    // claimed had restarted is demonstrably still in use. (After a confirmed
    // restart the candidate has done its job and goes for the same reason.)
    _restartCandidateBySender.remove(senderId);

    _expectedSeqBySender[senderId] = seq + 1;
    _lastChunkLenBySender[senderId] = samples.length;
    _enqueue(samples);

    if (_native != null) return;
    if (_filling && _queue.length >= _targetSamples) {
      _filling = false;
      _startDraining();
    }
  }

  /// Whether [seq] completes the evidence that [senderId]'s counter restarted.
  ///
  /// Each call either extends a run of consecutive far-behind packets or starts
  /// a new one. Only a run reaching [_restartConfirmChunks] returns true, and
  /// only the packet that completes it — everything before is dropped by the
  /// caller.
  bool _confirmsRestart(String senderId, int seq) {
    final candidate = _restartCandidateBySender[senderId];
    // "Continues the candidate" is the same test the established stream gets:
    // ordinary reordering behind it, an ordinary concealable gap ahead. A
    // far-behind packet that fits neither is a different stream again, so it
    // replaces the candidate rather than extending it.
    if (candidate == null ||
        seq < candidate.nextSeq - _maxReorderChunks ||
        seq > candidate.nextSeq + _maxConcealedGapChunks) {
      _restartCandidateBySender[senderId] = _RestartCandidate(seq + 1);
      return false;
    }
    candidate.nextSeq = seq + 1;
    candidate.chunks++;
    if (candidate.chunks < _restartConfirmChunks) return false;
    _restartCandidateBySender.remove(senderId);
    return true;
  }

  /// Counts a dropped far-behind packet and, at most every
  /// [_duplicateLogInterval], says so.
  ///
  /// The lag is the diagnostic worth having: a few hundred milliseconds is a
  /// slow second path, while seconds mean one route is buffering without
  /// bound and the peer should be looked at rather than the audio code.
  void _noteDuplicate(String senderId, int behind, int lastChunkLen) {
    final drops = (_duplicateDropsBySender[senderId] ?? 0) + 1;
    _duplicateDropsBySender[senderId] = drops;
    final stats = _stats(senderId);
    stats.duplicateDrops++;
    // The worst lag seen in the window, not the latest. A second path's delay
    // swings a lot; the peak is what decides whether it is a straggler worth
    // tolerating or a route holding seconds of audio.
    final lagMs = behind * lastChunkLen * 1000 ~/ _sampleRate;
    if (lagMs > stats.worstLagMs) stats.worstLagMs = lagMs;

    final now = DateTime.now();
    final lastLoggedAt = _duplicateLoggedAtBySender[senderId];
    if (lastLoggedAt != null &&
        now.difference(lastLoggedAt) < _duplicateLogInterval) {
      return;
    }
    _duplicateLoggedAtBySender[senderId] = now;
    Logger.diagnostic(
      'playback: sender $senderId heard twice — dropped $drops far-behind '
      'packets, newest lag ${lagMs}ms. This sender is reaching us by more '
      'than one network path; see the wifi SPLIT ROUTE line for which.',
    );
  }

  /// One line describing the whole playback stage, plus one per active sender.
  ///
  /// This used to go to [Logger.log], which is compiled out of release builds
  /// — so on the only phones that ever reproduce anything, the stage between
  /// "packets arrived" and "the user heard it" reported nothing at all. Every
  /// question about chopped, delayed, or repeating audio lands exactly here,
  /// and the answer was being discarded on the devices that had it.
  ///
  /// The counters are per window, not cumulative: what matters is whether the
  /// queue is starving or overflowing *now*, and a total that only ever grows
  /// answers that for nobody.
  void _logHealth({int? windowMs}) {
    // devUnderrun counts frames the DEVICE had to invent, which is the click
    // the user actually hears; `underruns` only counts this queue running dry.
    // They are different failures — the device can starve while this queue is
    // comfortably full, purely from timer jitter — so both are reported.
    final devFrames = _outputUnderrunFrames?.call() ?? 0;
    final devDelta = devFrames - _lastDeviceUnderrunFrames;
    _lastDeviceUnderrunFrames = devFrames;
    final windowSec = (windowMs ?? _logEveryTicks * _drainIntervalMs) / 1000;

    Logger.diagnostic(
      'playback: ${_queueMs}ms queued (target ${_ms(_targetSamples)}ms)'
      ' | ${windowSec.toStringAsFixed(0)}s window: fed ${_ms(_fedWindow)}ms'
      ' + concealed ${_ms(_concealedWindow)}ms'
      ' vs drained ${_ms(_drainedWindow)}ms'
      ' | underruns=$_underruns trims=$_trims jumps=$_jumps'
      ' overflow=$_overflowDrops'
      ' | device starved ${_ms(devDelta)}ms'
      ' (${_ms(devFrames)}ms total)'
      ' | device burst ${_ms(deviceBurstSamples)}ms',
    );

    // Per sender, and only for senders that actually delivered something in
    // the window — a channel of five people should not print four idle lines
    // to say so.
    for (final entry in _statsBySender.entries) {
      final s = entry.value;
      if (s.packets == 0) {
        s.idleWindows++;
        continue;
      }
      s.idleWindows = 0;
      Logger.diagnostic(
        'playback: sender ${entry.key} pkts=${s.packets} '
        'late=${s.lateDrops} dup=${s.duplicateDrops} '
        'resync=${s.resyncs} concealed=${s.concealedChunks} '
        'bigGaps=${s.bigGaps}'
        '${s.worstLagMs > 0 ? ' worstDupLag=${s.worstLagMs}ms' : ''}',
      );
      s.reset();
    }
    _statsBySender.removeWhere((_, s) => s.idleWindows > 4);

    _underruns = 0;
    _trims = 0;
    _jumps = 0;
    _overflowDrops = 0;
    _fedWindow = 0;
    _concealedWindow = 0;
    _drainedWindow = 0;
  }

  void _dropOverflow(int incoming) {
    final overflow = (_queue.length + incoming) - _maxQueueSamples;
    if (overflow > 0) {
      _overflowDrops++;
      _queue.discardFirst(overflow < _queue.length ? overflow : _queue.length);
    }
  }

  void _enqueue(List<double> samples) {
    if (_native != null) {
      _enqueueNative(samples);
      return;
    }
    _dropOverflow(samples.length);
    final start = _queue.length;
    _queue.addAll(samples);
    _fedWindow += samples.length;
    if (_fadeInNextFeed) {
      _fadeInNextFeed = false;
      // Ramped in the queue, never in [samples]: that list can be the
      // caller's own (see AudioEngineImpl.playReceived).
      final n = samples.length < _spliceFadeSamples
          ? samples.length
          : _spliceFadeSamples;
      for (var i = 0; i < n; i++) {
        _queue[start + i] *= (i + 1) / (n + 1);
      }
    }
  }

  /// Covers lost packets with silence, ramping the audio either side of it.
  ///
  /// A hole cut straight into a waveform starts and ends with a step, and a
  /// step is a click whatever the level around it. Only the part of the queue
  /// that has not been played yet can still be ramped, which is nearly always
  /// enough: the jitter buffer holds far more than one ramp.
  void _enqueueSilence(int count) {
    final native = _native;
    if (native != null) {
      _flushTail(fadeOut: true);
      _writeNative(null, count);
      _concealedWindow += count;
      _fadeInNextFeed = true;
      return;
    }
    _dropOverflow(count);
    final n = _queue.length < _spliceFadeSamples
        ? _queue.length
        : _spliceFadeSamples;
    final tailStart = _queue.length - n;
    for (var i = 0; i < n; i++) {
      _queue[tailStart + i] *= 1.0 - (i + 1) / (n + 1);
    }
    _queue.addZeros(count);
    _concealedWindow += count;
    _fadeInNextFeed = true;
  }

  void _enqueueNative(List<double> samples) {
    _ticksSinceFeed = 0;
    _fedWindow += samples.length;
    final held = _heldTail.length;
    final all = Float64List(held + samples.length)
      ..setAll(0, _heldTail)
      ..setAll(held, samples);
    if (_fadeInNextFeed) {
      _fadeInNextFeed = false;
      final n = samples.length < _spliceFadeSamples
          ? samples.length
          : _spliceFadeSamples;
      for (var i = 0; i < n; i++) {
        all[held + i] *= (i + 1) / (n + 1);
      }
    }
    final keep = all.length < _spliceFadeSamples
        ? all.length
        : _spliceFadeSamples;
    _writeNative(Float64List.sublistView(all, 0, all.length - keep), 0);
    _heldTail = Float64List.fromList(
      Float64List.sublistView(all, all.length - keep),
    );
  }

  /// Hands the held tail to the native queue, ramped down to silence when
  /// [fadeOut] (something is about to interrupt it).
  void _flushTail({required bool fadeOut}) {
    final tail = _heldTail;
    if (tail.isEmpty) return;
    _heldTail = Float64List(0);
    if (fadeOut) {
      for (var i = 0; i < tail.length; i++) {
        tail[i] *= 1.0 - (i + 1) / (tail.length + 1);
      }
    }
    _writeNative(tail, 0);
  }

  /// Speech is restarting from somewhere unrelated (a new talk burst, or a
  /// restarted sender). The held tail belongs to what came before: it is
  /// ramped out if that is still playing, and dropped if it already ran out
  /// (played now, it would be a stray blip in front of the new speech).
  void _nativeDiscontinuity() {
    final native = _native;
    if (native == null) return;
    if (native.isPlaying) {
      _flushTail(fadeOut: true);
      _fadeInNextFeed = true;
    } else {
      _heldTail = Float64List(0);
    }
  }

  void _writeNative(Float64List? samples, int silence) {
    final native = _native!;
    final wanted = samples?.length ?? silence;
    if (wanted == 0) return;
    final written = samples != null
        ? native.write(samples)
        : native.writeSilence(silence);
    // Only when the device has stopped pulling altogether: the jump back to
    // live keeps the native queue far below its capacity otherwise.
    if (written < wanted) _overflowDrops++;
  }

  void _nativeTick() {
    final native = _native!;
    final now = _NativeCounters.read(native);
    final last = _lastNative ?? now;
    _lastNative = now;

    // Grown on the underrun, as on the timer path — just noticed here rather
    // than in a drain callback, since the drain is native now.
    final newUnderruns = now.underruns - last.underruns;
    for (var i = 0; i < newUnderruns && i < 4; i++) {
      _underruns++;
      _growTarget();
    }
    // The talker stopped. VOX senders keep their numbering across a pause,
    // so the next burst will not look like a gap, and the tail would play in
    // front of it; settle it now instead.
    if (_heldTail.isNotEmpty && ++_ticksSinceFeed >= _staleTailTicks) {
      _nativeDiscontinuity();
      _fadeInNextFeed = false;
    }
    _trims += now.trims - last.trims;
    _jumps += now.jumps - last.jumps;
    _drainedWindow += now.played - last.played;

    if (++_nativeTicks % (_adaptIntervalMs ~/ _nativeTickMs) == 0) {
      _adaptStep();
    }
    native.targetFrames = _targetSamples;

    if (debugLogging && _nativeTicks % (_logIntervalMs ~/ _nativeTickMs) == 0) {
      _logHealth(windowMs: _logIntervalMs);
    }
  }

  /// Drop one small step off the stale head, walking playback latency down
  /// toward target.
  ///
  /// This is the only thing that lowers latency here, and it is purely a
  /// content operation — the drain keeps pushing its fixed slice per tick
  /// either way.
  ///
  /// The two sides of the cut are crossfaded rather than butted together.
  /// This used to discard the step and then fade the next slice in from zero,
  /// which is a 3 ms dip to silence in the middle of speech: on a queue
  /// sitting above its threshold that happened every 200 ms, and it was
  /// audible as a tick every time.
  void _trimStep({bool toTarget = false}) {
    final excess = _queue.length - _targetSamples;
    if (excess <= 0) return;
    final step = toTarget || excess < _trimStepSamples
        ? excess
        : _trimStepSamples;
    final fade = _spliceFadeSamples;
    // The overlap itself shortens the queue by [fade], so only the rest of
    // the step is cut outright.
    final cut = step > fade ? step - fade : 0;
    // Needs a full fade on both sides of the cut; above the trim threshold the
    // queue always has it, so this only guards very small test buffers.
    if (_queue.length < fade + cut + fade) return;
    final before = _queue.takeFirst(fade);
    _queue.discardFirst(cut);
    for (var i = 0; i < fade; i++) {
      final w = (i + 1) / (fade + 1);
      _queue[i] = before[i] * (1.0 - w) + _queue[i] * w;
    }
    // [before] came off the head, so the crossfade now starts the queue: it is
    // exactly what the next slice would have played, joined smoothly to what
    // comes after the cut.
    if (!toTarget) _trims++;
  }

  void _startDraining() {
    _drainTimer?.cancel();
    _fadeRemaining = _fadeInSamples;
    _sinceTrimTicks = 0;
    _lastDrainTick = 0;
    // Hand the native ring its cushion before the first slice, so the very
    // first late tick doesn't underrun. Silence, so it costs latency but no
    // content — and it is inaudible ahead of the fade-in below. Only what the
    // ring is actually missing, when it can say: a drain restarting right
    // after an underrun can find part of the old cushion still there.
    final queued = _outputQueuedFrames?.call() ?? -1;
    final prefill = queued < 0
        ? _prefillSamples
        : (_prefillSamples - queued).clamp(0, _prefillSamples);
    if (prefill > 0) _output.add(Float64List(prefill));
    _levelAfterLastTick = queued < 0 ? -1 : queued + prefill;
    _drainTimer = Timer.periodic(Duration(milliseconds: _drainIntervalMs), (
      timer,
    ) {
      if (debugLogging && ++_logTicks >= _logEveryTicks) {
        _logTicks = 0;
        _logHealth();
      }

      // Its own window, not the log's: the two run at very different periods,
      // and sharing counters would have each steal the other's evidence — the
      // same trap TransportStats was built to avoid on the transport side.
      if (++_adaptTicks >= _adaptEveryTicks) {
        _adaptTicks = 0;
        _adaptStep();
      }

      final slices = _slicesDue(timer.tick);
      for (var i = 0; i < slices; i++) {
        if (!_drainSlice()) return;
      }
    });
  }

  /// How many slices this tick owes the device. See the class doc's cadence
  /// section for why this is not simply one.
  int _slicesDue(int tick) {
    final periods = tick - _lastDrainTick;
    _lastDrainTick = tick;
    final queued = _outputQueuedFrames?.call() ?? -1;
    int due;
    if (queued >= 0) {
      _noteDeviceBurst(queued);
      var cushion = _prefillSamples + deviceBurstSamples;
      if (cushion > _maxCushionSamples) cushion = _maxCushionSamples;
      final missing = cushion - queued;
      due = missing <= 0 ? 0 : (missing + _drainSize - 1) ~/ _drainSize;
      if (due > _maxSlicesPerTick) due = _maxSlicesPerTick;
      // Assumes every slice is written; an underrun stops the drain, and the
      // next start re-reads the ring anyway.
      _levelAfterLastTick = queued + due * _drainSize;
    } else {
      due = periods < 1 ? 1 : periods;
    }
    return due > _maxSlicesPerTick ? _maxSlicesPerTick : due;
  }

  void _noteDeviceBurst(int queued) {
    if (_levelAfterLastTick >= 0) {
      final taken = _levelAfterLastTick - queued;
      if (taken > _burstThisWindow) _burstThisWindow = taken;
    }
    if (++_burstWindowTicks >= _burstWindowLength) {
      _burstWindowTicks = 0;
      _burstLastWindow = _burstThisWindow;
      _burstThisWindow = 0;
    }
  }

  /// Pushes one slice, or stops the drain on an underrun. Returns whether the
  /// drain is still running.
  bool _drainSlice() {
    if (_queue.length < _drainSize) {
      // Underrun — stop and wait for the buffer to refill, but ramp down on
      // the way out. Stopping mid-waveform leaves the signal at whatever
      // level it happened to reach and the device then plays silence: a step
      // discontinuity, i.e. exactly the click the fade-in below exists to
      // avoid on the way back.
      //
      // The ramp has to be synthesised rather than just applied to what's
      // left, because the queue usually empties on an exact slice boundary
      // and there IS nothing left — the step still happens. So the leftover
      // (if any) is followed by a short decay from the last level to zero.
      // Variable-length, but only on the path where the drain is stopping
      // anyway, so it cannot affect the steady cadence.
      final remaining = _queue.length;
      final tail = Float64List(remaining + _fadeOutSamples);
      for (var i = 0; i < remaining; i++) {
        tail[i] = _queue[i];
      }
      final hold = remaining > 0 ? tail[remaining - 1] : _lastEmittedSample;
      for (var i = remaining; i < tail.length; i++) {
        tail[i] = hold;
      }
      for (var i = 0; i < tail.length; i++) {
        tail[i] *= 1.0 - (i + 1) / tail.length;
      }
      _queue.discardFirst(remaining);
      _output.add(tail);
      _drainedWindow += tail.length;
      _lastEmittedSample = 0.0;

      _underruns++;
      // The strongest evidence the depth is too shallow, and acted on here
      // rather than at the next window boundary — the drain timer is about to
      // be cancelled, so waiting for a tick would mean growing slowest under
      // exactly the conditions that need it fastest.
      _growTarget();
      _filling = true;
      _drainTimer?.cancel();
      _drainTimer = null;
      return false;
    }

    // Backlog above target: walk it down one small step at a time. A burst
    // after a network stall, or a sender whose clock runs a little fast, still
    // leaves more queued than the drain plays, so the difference has to be
    // given back somewhere, and small steps are far less audible than one
    // splice.
    if (_queue.length > _jumpThreshold) {
      _sinceTrimTicks = 0;
      _trimStep(toTarget: true);
      _jumps++;
    } else if (_queue.length > _trimThreshold) {
      if (++_sinceTrimTicks >= _trimIntervalTicks) {
        _sinceTrimTicks = 0;
        _trimStep();
      }
    } else {
      _sinceTrimTicks = 0;
    }

    final chunk = _queue.takeFirst(_drainSize);
    _drainedWindow += _drainSize;
    if (_fadeRemaining > 0) {
      final rampLen = _fadeRemaining < chunk.length
          ? _fadeRemaining
          : chunk.length;
      for (int i = 0; i < rampLen; i++) {
        final progress =
            (_fadeInSamples - _fadeRemaining + i + 1) / _fadeInSamples;
        chunk[i] *= progress.clamp(0.0, 1.0);
      }
      _fadeRemaining -= rampLen;
    }
    if (chunk.isNotEmpty) _lastEmittedSample = chunk[chunk.length - 1];
    _output.add(chunk);
    return true;
  }

  /// Reset the buffer state (e.g. on network reconnect).
  void reset() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _queue.clear();
    _native?.reset();
    _heldTail = Float64List(0);
    _filling = true;
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
    _restartCandidateBySender.clear();
    _duplicateDropsBySender.clear();
    _duplicateLoggedAtBySender.clear();
    _resyncLoggedAtBySender.clear();
    _statsBySender.clear();
    _fadeRemaining = 0;
    _fadeInNextFeed = false;
    _sinceTrimTicks = 0;
    // The in-progress evidence goes, because it describes a stream that has
    // just been discarded. The learned depth deliberately does NOT: this runs
    // on a reconnect, and a reconnect mid-ride is overwhelmingly the same link
    // with the same jitter. Starting over at the configured depth would pay for
    // the lesson again in underruns — audible ones — while keeping it costs at
    // most a few seconds of extra latency that shrinks itself back out.
    _adaptTicks = 0;
    _calmWindows = 0;
    _lateDropsSinceAdapt = 0;
  }

  /// Cancel the drain timer. Call before discarding this object.
  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _nativeTimer?.cancel();
    _nativeTimer = null;
  }
}

/// What happened to one sender's stream in one reporting window.
///
/// Counters rather than events: each of these fires far too often to log
/// individually (a split delivery route produces thousands of resyncs a
/// minute), and the rate is the diagnostic anyway — one resync is normal,
/// three hundred a minute is a broken session.
class _SenderStats {
  int packets = 0;

  /// Arrived behind what we are playing, but close enough to be ordinary UDP
  /// reordering. A few is healthy; a steady stream means real jitter.
  int lateDrops = 0;

  /// Arrived so far behind it can only be a second copy of audio we already
  /// played. Non-zero here means multi-path delivery, full stop.
  int duplicateDrops = 0;

  /// Times the stream's numbering was accepted as having restarted. Should be
  /// ~0. Repeated resyncs mean two numberings are fighting for the stream.
  int resyncs = 0;

  /// Missing packets papered over with silence — small holes in speech.
  int concealedChunks = 0;

  /// Gaps too large to conceal, resumed mid-stream — heard as speech starting
  /// abruptly. Normal at the start of each talk burst.
  int bigGaps = 0;

  /// Worst delay seen on a duplicate copy this window.
  int worstLagMs = 0;

  /// Consecutive windows with no traffic, so a peer who left is eventually
  /// forgotten instead of accumulating map entries for the session's life.
  int idleWindows = 0;

  void reset() {
    packets = 0;
    lateDrops = 0;
    duplicateDrops = 0;
    resyncs = 0;
    concealedChunks = 0;
    bigGaps = 0;
    worstLagMs = 0;
  }
}

/// A run of consecutive packets numbered well below what a sender was last
/// playing at — the shape a restarted counter makes, and also the shape a
/// second delivery path makes. See [AudioPlaybackBuffer._confirmsRestart].
class _RestartCandidate {
  _RestartCandidate(this.nextSeq);

  /// Sequence the run expects next, so the following packet can be checked
  /// against it the same way the established stream is.
  int nextSeq;

  /// Packets seen on this run so far.
  int chunks = 1;
}

/// Snapshot of the native queue's cumulative counters, so each housekeeping
/// tick can work in deltas.
class _NativeCounters {
  _NativeCounters(this.underruns, this.trims, this.jumps, this.played);

  factory _NativeCounters.read(VoiceQueue q) =>
      _NativeCounters(q.underruns, q.trims, q.jumps, q.playedFrames);

  final int underruns;
  final int trims;
  final int jumps;
  final int played;
}
