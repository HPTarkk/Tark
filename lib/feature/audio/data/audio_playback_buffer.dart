import 'dart:async';
import 'dart:typed_data';

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
/// The drain pushes a **fixed [_drainSize] samples per tick**. This looks like
/// something worth "improving" — a periodic timer on the UI isolate is
/// imprecise, so draining a fixed slice per tick doesn't track real time
/// exactly. Replacing it with an elapsed-wall-clock drain (variable samples
/// per tick, matching real time) was tried and produced badly chopped audio on
/// Bluetooth, repeatedly, across several tunings of depth and thresholds. The
/// fixed cadence is the only cadence this pipeline is known to play cleanly.
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
  }) : _output = output,
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
       _outputUnderrunFrames = outputUnderrunFrames;

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
  int get _queueMs => _ms(_queue.length);

  /// Samples currently waiting to be played. Exposed for diagnostics and for
  /// tests that need to assert on concealment/drop decisions directly, rather
  /// than inferring them from what eventually reaches the device.
  int get queuedSamples => _queue.length;

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
    if (lastLoggedAt != null && now.difference(lastLoggedAt) < _duplicateLogInterval) {
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
  void _logHealth() {
    // devUnderrun counts frames the DEVICE had to invent, which is the click
    // the user actually hears; `underruns` only counts this queue running dry.
    // They are different failures — the device can starve while this queue is
    // comfortably full, purely from timer jitter — so both are reported.
    final devFrames = _outputUnderrunFrames?.call() ?? 0;
    final devDelta = devFrames - _lastDeviceUnderrunFrames;
    _lastDeviceUnderrunFrames = devFrames;
    final windowSec = _logEveryTicks * _drainIntervalMs / 1000;

    Logger.diagnostic(
      'playback: ${_queueMs}ms queued (target ${_ms(_targetSamples)}ms)'
      ' | ${windowSec.toStringAsFixed(0)}s window: fed ${_ms(_fedWindow)}ms'
      ' + concealed ${_ms(_concealedWindow)}ms'
      ' vs drained ${_ms(_drainedWindow)}ms'
      ' | underruns=$_underruns trims=$_trims overflow=$_overflowDrops'
      ' | device starved ${_ms(devDelta)}ms'
      ' (${_ms(devFrames)}ms total)',
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
    _dropOverflow(samples.length);
    _queue.addAll(samples);
    _fedWindow += samples.length;
  }

  void _enqueueSilence(int count) {
    _dropOverflow(count);
    _queue.addZeros(count);
    _concealedWindow += count;
  }

  /// Drop one small step off the stale head, walking playback latency down
  /// toward target.
  ///
  /// This is the only thing that lowers latency here, and it is purely a
  /// content operation — the drain keeps pushing its fixed slice per tick
  /// either way.
  void _trimStep() {
    final excess = _queue.length - _targetSamples;
    if (excess <= 0) return;
    _queue.discardFirst(excess < _trimStepSamples ? excess : _trimStepSamples);
    _fadeRemaining = _fadeInSamples;
    _trims++;
  }

  void _startDraining() {
    _drainTimer?.cancel();
    _fadeRemaining = _fadeInSamples;
    _sinceTrimTicks = 0;
    // Hand the native ring its cushion before the first slice, so the very
    // first late tick doesn't underrun. Silence, so it costs latency but no
    // content — and it is inaudible ahead of the fade-in below.
    if (_prefillSamples > 0) _output.add(Float64List(_prefillSamples));
    _drainTimer = Timer.periodic(Duration(milliseconds: _drainIntervalMs), (_) {
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
        return;
      }

      // Backlog above target: walk it down one small step at a time. The feed
      // outruns this fixed-cadence drain — that is how the session used to
      // accumulate a multi-second delay — so the difference has to be given
      // back somewhere, and small steps are far less audible than one splice.
      if (_queue.length > _trimThreshold) {
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
    });
  }

  /// Reset the buffer state (e.g. on network reconnect).
  void reset() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _queue.clear();
    _filling = true;
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
    _restartCandidateBySender.clear();
    _duplicateDropsBySender.clear();
    _duplicateLoggedAtBySender.clear();
    _resyncLoggedAtBySender.clear();
    _statsBySender.clear();
    _fadeRemaining = 0;
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
