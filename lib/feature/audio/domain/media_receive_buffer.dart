import 'float64_fifo.dart';

/// Windowed receiver-health snapshot for Shared Music.
///
/// Values are deliberately transport-agnostic and contain no sender identity,
/// address, room data, or audio. They are safe to surface in diagnostics and
/// feed into #41's media-quality policy.
class MediaReceiveHealth {
  const MediaReceiveHealth({
    required this.queuedMs,
    required this.underruns,
    required this.outputStarvations,
    required this.trims,
    required this.overflowDrops,
    required this.staleDrops,
    required this.duplicateDrops,
    required this.resyncs,
    required this.concealedMs,
  });

  final int queuedMs;
  final int underruns;
  final int outputStarvations;
  final int trims;
  final int overflowDrops;
  final int staleDrops;
  final int duplicateDrops;
  final int resyncs;
  final int concealedMs;

  bool get isDistressed =>
      overflowDrops > 0 ||
      staleDrops > 0 ||
      resyncs > 0 ||
      underruns > 0 ||
      outputStarvations > 0;
}

/// Independent receive-side jitter buffer for Shared Music.
///
/// Music has different failure semantics from speech. A very short hole can be
/// concealed, but manufacturing hundreds of milliseconds of silence or
/// replaying a stale queue is worse than making one clean discontinuity and
/// returning to live audio. This buffer therefore has an explicit playable
/// latency ceiling and treats a large sequence jump as a resync boundary.
///
/// It is pull-based and owns no timer. `AudioEngineImpl` remains the only owner
/// of output cadence, mixing media into the existing voice output path.
class MediaReceiveBuffer {
  MediaReceiveBuffer({
    int sampleRate = 48000,
    int targetBufferMs = kDefaultTargetBufferMs,
    int maxQueueMs = kDefaultMaxQueueMs,
    int maxConcealMs = kDefaultMaxConcealMs,
  }) : assert(sampleRate > 0),
       assert(targetBufferMs >= 0),
       assert(maxQueueMs >= targetBufferMs),
       assert(maxConcealMs >= 0),
       _sampleRate = sampleRate,
       _targetSamples = sampleRate * targetBufferMs ~/ 1000,
       _maxQueueSamples = sampleRate * maxQueueMs ~/ 1000,
       _maxConcealSamples = sampleRate * maxConcealMs ~/ 1000 {
    // AudioEngine owns one active media receive buffer at a time. Publishing
    // that owner here lets the existing transport heartbeat sample receiver
    // health without adding another AudioEngine/transport dependency or timer.
    // A new engine/buffer supersedes an old one; dispose clears only itself.
    _active = this;
  }

  static MediaReceiveBuffer? _active;

  /// Returns and clears the active receiver's event window only after at least
  /// one real media packet established a sender sequence. Before that there is
  /// no receiver evidence to advertise and callers must stay unconfirmed.
  static MediaReceiveHealth? takeActiveHealthWindow() {
    final active = _active;
    if (active == null || active._expectedSeqBySender.isEmpty) return null;
    return active.takeHealthWindow();
  }

  /// Enough cushion for ordinary mobile jitter without making a late music
  /// stream feel detached from what the sender is actually playing.
  static const int kDefaultTargetBufferMs = 120;

  /// Hard playable-latency ceiling. The previous 1500 ms cap allowed an old
  /// stream to stay audible more than a second after a disruption. For shared
  /// music, a controlled discontinuity is preferable to that much stale audio.
  static const int kDefaultMaxQueueMs = 400;

  /// Only tiny holes are concealed. At the 20 ms media packet cadence this is
  /// at most two missing packets; anything larger becomes an explicit resync.
  static const int kDefaultMaxConcealMs = 40;

  final int _sampleRate;
  final int _targetSamples;
  final int _maxQueueSamples;
  final int _maxConcealSamples;
  late final int _trimStepSamples = _sampleRate * 10 ~/ 1000;

  final Float64Fifo _queue = Float64Fifo(4096);
  bool _filling = true;

  final Map<String, int> _expectedSeqBySender = {};
  final Map<String, int> _lastChunkLenBySender = {};

  int _underruns = 0;
  int _outputStarvations = 0;
  int _trims = 0;
  int _overflowDrops = 0;
  int _staleDrops = 0;
  int _duplicateDrops = 0;
  int _resyncs = 0;
  int _concealedSamples = 0;

  int get queuedSamples => _queue.length;
  int get queuedMs => _queue.length * 1000 ~/ _sampleRate;
  int get targetSamples => _targetSamples;
  int get underruns => _underruns;
  int get outputStarvations => _outputStarvations;
  int get trims => _trims;
  int get overflowDrops => _overflowDrops;
  int get staleDrops => _staleDrops;
  int get duplicateDrops => _duplicateDrops;
  int get resyncs => _resyncs;
  int get concealedSamples => _concealedSamples;
  int get concealedMs => _concealedSamples * 1000 ~/ _sampleRate;
  bool get isFilling => _filling;

  MediaReceiveHealth get health => _snapshot();

  /// Returns receiver evidence for the current diagnostics/adaptation window
  /// and clears only the event counters. Queue depth remains an instantaneous
  /// gauge and sequence/playback state is untouched.
  MediaReceiveHealth takeHealthWindow() {
    final snapshot = _snapshot();
    _underruns = 0;
    _outputStarvations = 0;
    _trims = 0;
    _overflowDrops = 0;
    _staleDrops = 0;
    _duplicateDrops = 0;
    _resyncs = 0;
    _concealedSamples = 0;
    return snapshot;
  }

  MediaReceiveHealth _snapshot() => MediaReceiveHealth(
    queuedMs: queuedMs,
    underruns: _underruns,
    outputStarvations: _outputStarvations,
    trims: _trims,
    overflowDrops: _overflowDrops,
    staleDrops: _staleDrops,
    duplicateDrops: _duplicateDrops,
    resyncs: _resyncs,
    concealedMs: concealedMs,
  );

  /// Feed one decoded media frame. [seq] is scoped to [senderId] and remains
  /// independent of voice sequence numbers.
  void feed(List<double> samples, int seq, String senderId) {
    if (samples.isEmpty) return;

    final expectedSeq = _expectedSeqBySender[senderId];
    final lastChunkLen = _lastChunkLenBySender[senderId] ?? samples.length;

    if (expectedSeq == null) {
      // First packet from this sender: establish the baseline below.
    } else if (seq < expectedSeq) {
      final behind = expectedSeq - seq;
      if (behind == 1) {
        _duplicateDrops++;
      } else {
        _staleDrops++;
      }

      // A true sender/session restart is already known to higher layers via
      // session epoch/reconnect and calls reset(). Guessing a restart from one
      // far-behind packet lets delayed audio overwrite the live baseline, so
      // every behind packet is rejected here regardless of distance.
      return;
    } else if (seq > expectedSeq) {
      final missing = seq - expectedSeq;
      final gapSamples = missing * lastChunkLen;
      if (gapSamples <= _maxConcealSamples) {
        _concealedSamples += gapSamples;
        _enqueueSilence(gapSamples);
      } else {
        _resyncToLiveEdge();
      }
    }

    _expectedSeqBySender[senderId] = seq + 1;
    _lastChunkLenBySender[senderId] = samples.length;
    _enqueue(samples);
  }

  void _resyncToLiveEdge() {
    _resyncs++;
    _queue.clear();
    _filling = true;
  }

  void _enqueue(List<double> samples) {
    _queue.addAll(samples);
    _dropOverflow();
  }

  void _enqueueSilence(int count) {
    if (count <= 0) return;
    _queue.addZeros(count);
    _dropOverflow();
  }

  /// The cap is strict after every write. Overflow discards oldest media so the
  /// receiver always converges toward the live edge instead of preserving a
  /// stale head and dropping the newest audio.
  void _dropOverflow() {
    if (_queue.length <= _maxQueueSamples) return;
    _overflowDrops++;
    _queue.discardFirst(_queue.length - _maxQueueSamples);
  }

  /// Pulls one output frame once the initial cushion is ready.
  ///
  /// Mild clock drift is corrected in 10 ms steps whenever queue growth gets
  /// materially above target. A sudden large backlog is handled more strongly:
  /// all excess beyond target is dropped in one operation, because slowly
  /// walking a 300-400 ms stale queue down would make latency audible for many
  /// seconds.
  List<double>? pullFrame(int count) {
    if (count <= 0) return const [];

    if (_filling) {
      if (_queue.length < _targetSamples) return null;
      _filling = false;
    }

    final highWater = _targetSamples + (_targetSamples ~/ 2);
    if (_queue.length > highWater) {
      final excess = _queue.length - _targetSamples;
      final severeBacklog = _queue.length >= _maxQueueSamples * 3 ~/ 4;
      final trim = severeBacklog
          ? excess
          : (excess < _trimStepSamples ? excess : _trimStepSamples);
      if (trim > 0) {
        _queue.discardFirst(trim);
        _trims++;
      }
    }

    if (_queue.length < count) {
      _underruns++;
      _outputStarvations++;
      _filling = true;
      return null;
    }
    return _queue.takeFirst(count);
  }

  /// Explicit stream boundary (reconnect, sender epoch renewal, profile
  /// restart). This is the only way a far-behind sequence is allowed to become
  /// a fresh baseline, which prevents delayed packets from impersonating a
  /// restart.
  void reset() {
    _queue.clear();
    _filling = true;
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
  }

  /// No timer is owned here; disposal only releases buffered audio/state.
  void dispose() {
    if (identical(_active, this)) _active = null;
    _queue.clear();
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
  }
}
