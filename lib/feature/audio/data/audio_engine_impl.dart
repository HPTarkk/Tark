import 'dart:async';
import 'dart:math';

import 'package:audio_io/audio_io.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/settings/noise_suppression_engine.dart';
import '../../../core/settings/settings_repository.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/permission_queue.dart';
import '../domain/audio_processor.dart';
import '../domain/entity/audio_engine_status.dart';
import '../domain/entity/audio_frame.dart';
import '../domain/float64_fifo.dart';
import '../domain/resampler.dart';
import '../domain/rnnoise_suppressor.dart';
import '../domain/service/audio_engine.dart';
import '../domain/spectral_noise_suppressor.dart';
import 'audio_playback_buffer.dart';
import 'voice_audio_session.dart';

@Injectable(as: AudioEngine)
class AudioEngineImpl implements AudioEngine {
  AudioEngineImpl(this._audioIo, this._settingsRepository);

  final AudioIo _audioIo;
  final SettingsRepository _settingsRepository;

  // ── Engine ownership ───────────────────────────────────────────────────
  // AudioIo is a process-wide singleton, but AudioEngineImpl instances come
  // and go with the walkie page — and the owning cubit is disposed WITHOUT
  // awaiting its close(). A stale dispose() can therefore still be running
  // (its awaits can lag by seconds) when the next page's session starts the
  // engine. Two static guards make that safe:
  //  * _engineLock serializes stop/start transitions. audio_io's FFI layer
  //    wedges permanently if they interleave: its stop() clears the running
  //    flag, suspends on controller closes, then destroys whatever handle
  //    the singleton currently holds — which by then is the handle a
  //    concurrent start() just created — while start() has already set the
  //    running flag back to true, so every later start() no-ops forever.
  //  * _engineEpoch tracks which session owns the engine, so a stale
  //    dispose() skips its stop instead of killing the newer session's mic.
  static int _engineEpoch = 0;
  static Future<void> _engineLock = Future<void>.value();
  int _myEpoch = -1;

  static Future<void> _withEngineLock(Future<void> Function() action) {
    final run = _engineLock.then((_) => action());
    _engineLock = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _stopEngineIfOwned() => _withEngineLock(() async {
    if (_engineEpoch != _myEpoch) return; // newer session owns the engine
    await _audioIo.stop();
    await VoiceAudioSession.release();
  });

  AudioProcessor _processor = AudioProcessor(
    sampleRate: kTxSampleRate.toDouble(),
  );

  // Noise suppression on the 16 kHz mic signal, applied BEFORE frames are
  // emitted so both the VOX RMS decision and the visualizer see the cleaned
  // signal. That's the point: with noise subtracted, a low VOX threshold no
  // longer keys up on noise. Two suppressors, user-selectable in Advanced
  // settings (either alone, or cascaded via NoiseSuppressionEngine.both) —
  // both kept warm (reset when idle costs nothing) so switching engines
  // mid-session doesn't need to rebuild anything.
  final SpectralNoiseSuppressor _spectralSuppressor = SpectralNoiseSuppressor();
  final RnnoiseSuppressor _rnnoiseSuppressor = RnnoiseSuppressor();
  NoiseSuppressionEngine _suppressionEngine = NoiseSuppressionEngine.spectral;

  AudioPlaybackBuffer? _buffer;
  StreamSubscription<List<double>>? _inputSub;
  final StreamController<AudioFrame> _frameController =
      StreamController<AudioFrame>.broadcast();
  final StreamController<AudioFrame> _receivedFrameController =
      StreamController<AudioFrame>.broadcast();

  bool _disposed = false;

  // ── Stall watchdog ─────────────────────────────────────────────────────
  // audio_io captures continuously (VOX is always recording), so mic frames
  // should arrive every few ms whenever the engine is up. If they stop for
  // longer than [_kStallTimeout] — the classic symptom is starting media
  // playback on the same phone, which interrupts the VOICE_COMMUNICATION
  // streams and they never self-recover — restart the engine instead of
  // making the user leave and rejoin the channel. Also heals audio-route
  // changes and transient AAudio errors.
  Timer? _watchdog;
  DateTime _lastInputAt = DateTime.now();
  DateTime _lastRestartAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _restarting = false;
  static const _kStallTimeout = Duration(seconds: 3);
  static const _kMinRestartInterval = Duration(seconds: 5);
  static const _kWatchdogInterval = Duration(seconds: 2);

  /// When the watchdog last actually ran.
  ///
  /// [_lastInputAt] is advanced from `_onInput`, on the UI isolate. When the OS
  /// suspends that isolate — the phone locked, the app backgrounded — frames
  /// stop being *delivered* while the mic itself is fine, and nothing is
  /// running to notice either way. On resume the watchdog would find
  /// [_lastInputAt] as old as the nap and restart a working engine.
  ///
  /// That restart is not free: it tears the duplex VOICE_COMMUNICATION device
  /// down and reopens it, and on Android that is exactly the churn that makes
  /// another app's media playback pause itself. The logs behind this fix show
  /// phones backgrounded over and over (naps of 4.8 s, 16.6 s, 31.2 s, 33.7 s),
  /// every one of them long past [_kStallTimeout] — so the user's music was
  /// being stopped by a watchdog reacting to the screen going off.
  ///
  /// This timer firing on schedule is the proof that we were awake to judge the
  /// mic at all, so the gap it reports is what gets discounted below.
  DateTime _lastWatchdogAt = DateTime.now();

  /// Ordinary lateness for a timer sharing an isolate with rendering. Anything
  /// past this is the isolate not having run, not jitter.
  static const _kWatchdogJitter = Duration(milliseconds: 500);

  // ── Route changes ──────────────────────────────────────────────────────
  // Headsets that arrive AFTER the engine is up are their own problem: the
  // route is chosen once, in _openStreams, and on Android it is *pinned*
  // (setCommunicationDevice on the built-in speaker when nothing was
  // attached), which outranks the headset the call strategy would otherwise
  // pick. Connecting one mid-session left both capture and playback on the
  // phone. Re-pick the device and re-open the streams on every change.
  StreamSubscription<void>? _routeSub;
  Timer? _routeSettle;
  static const _kRouteSettleDelay = Duration(milliseconds: 800);

  AudioEngineStatus _currentStatus = AudioEngineStatus.initial();
  final StreamController<AudioEngineStatus> _statusController =
      StreamController<AudioEngineStatus>.broadcast();

  void _setStatus(AudioEngineStatus status) {
    _currentStatus = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  // TX path: device mic rate → anti-alias filter → 16 kHz → fixed 20 ms frames.
  // Two cascaded one-pole stages give a steeper (~12 dB/octave) rolloff than
  // a single stage, which matters here: a gentle single-pole filter lets
  // energy above the new Nyquist (8 kHz) fold back as audible hiss/noise
  // when downsampling from 44.1/48 kHz to 16 kHz.
  OnePoleLowPass? _txLowPassA;
  OnePoleLowPass? _txLowPassB;
  LinearResampler? _txResampler;
  final Float64Fifo _txAccum = Float64Fifo();

  // RX path: 16 kHz network audio → device output rate.
  LinearResampler? _rxResampler;

  @override
  Stream<AudioFrame> get frames => _frameController.stream;

  @override
  Stream<AudioFrame> get receivedFrames => _receivedFrameController.stream;

  @override
  Stream<AudioEngineStatus> get status => _statusController.stream;

  @override
  AudioEngineStatus get currentStatus => _currentStatus;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> start() async {
    // Claim engine ownership synchronously, before the first await: any
    // stale dispose() that runs from here on sees a newer epoch and won't
    // stop the engine out from under this session.
    _myEpoch = ++_engineEpoch;

    // On web there is no permission_handler backend worth relying on — the
    // browser shows its own prompt when getUserMedia runs inside
    // audio_io.start(), so treat a throwing/absent handler as "ask later".
    var micGranted = true;
    try {
      // Queued: the Bluetooth flow can be raising its own dialog at this exact
      // moment, and Android drops whichever request comes second — leaving
      // this await hanging forever. See [PermissionQueue].
      micGranted = (await PermissionQueue.run(
        () => Permission.microphone.request(),
      )).isGranted;
    } catch (e) {
      Logger.log('Mic permission request unavailable: $e');
    }
    if (!micGranted) {
      if (!_disposed) {
        _setStatus(
          const AudioEngineStatus(hasPermission: false, isStarted: false),
        );
      }
      return;
    }

    var started = false;
    await _withEngineLock(() async {
      // Superseded by a newer session, or disposed while waiting for the
      // permission dialog / lock — the engine belongs to someone else now.
      if (_engineEpoch != _myEpoch || _disposed) return;
      await _openStreams();
      started = true;
    });

    if (_disposed) {
      // dispose() ran while we were starting — shut the engine back down.
      await _inputSub?.cancel();
      await _stopEngineIfOwned();
      return;
    }
    if (started) {
      _setStatus(const AudioEngineStatus(hasPermission: true, isStarted: true));
      _startWatchdog();
      _watchRouteChanges();
    }
  }

  /// Opens (or re-opens) the mic + speaker streams and wires the input
  /// listener. Must run inside [_withEngineLock] with epoch/disposed already
  /// checked — shared by [start] and the stall/route restarts so all of them
  /// go through the exact same route/effects/resampler setup.
  ///
  /// [renegotiateRoute] discards the device the session already selected
  /// before choosing again; only a restart caused by a device appearing or
  /// disappearing needs it.
  Future<void> _openStreams({bool renegotiateRoute = false}) async {
    try {
      // Before the device goes down, not after the new one comes up.
      //
      // [_audioIo.stop] closes the output sink, and the buffer below drains
      // into it on a 10 ms timer. Disposing it at the far end of this method
      // instead left that timer running across the whole reopen — the route
      // settle alone is 700 ms, plus a start that may retry after 300 ms — so
      // for a second or more every tick threw `Bad state: Cannot add event
      // after closing` out of a Timer callback, where nothing could catch it.
      // Seen in the field on a Galaxy A53 (1.0.14+15), and for that whole
      // window received audio went nowhere: the buffer was still draining, but
      // into a sink that was gone.
      _buffer?.dispose();
      _buffer = null;
      await _audioIo.stop();
      // Android: bring the Bluetooth SCO route up — and confirmed — BEFORE
      // the engine opens its streams. Older devices don't re-route streams
      // that are already open (Galaxy S8 + AirPods went silent both ways).
      // No-op without a BT headset; rolls itself back if SCO fails so the
      // default route keeps working.
      if (renegotiateRoute) {
        await VoiceAudioSession.reconfigure();
      } else {
        await VoiceAudioSession.configure();
      }
      await _audioIo.requestLatency(AudioIoLatency.Balanced);
      try {
        await _audioIo.start();
      } catch (_) {
        // Re-opening the duplex device right after a teardown can fail
        // transiently on some Android devices — give it one more chance.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _audioIo.start();
      }
      // iOS: re-assert the voiceChat category AFTER start — miniaudio
      // applies its own session config during start and last write wins.
      // On Android this second call is a no-op (already engaged).
      await VoiceAudioSession.configure();

      // Android: attach the platform AEC/NS/AGC to the now-open capture
      // stream's audio session. -1 elsewhere (iOS/web/OpenSL) → no-op, and
      // those paths still get processing from the voice preset / voiceChat.
      final sessionId = await _audioIo.inputSessionId();
      await VoiceAudioSession.attachEffects(sessionId);

      final fmt = await _audioIo.getFormat();
      final inputRate =
          (fmt?['input']?['sampleRate'] as num?)?.toDouble() ?? 48000.0;
      final outputRate =
          (fmt?['output']?['sampleRate'] as num?)?.toDouble() ?? inputRate;
      // Diagnostic, not debug: the rates the OS actually handed us decide
      // every resampler ratio downstream, and a device that negotiates
      // something unexpected (16 kHz capture over a Bluetooth headset, a
      // 44.1 kHz output) changes how the whole pipeline sounds. Reported
      // once per session start, where a fault is either present or absent —
      // and previously only on a debug build, i.e. never on the phone that
      // had the problem.
      Logger.diagnostic(
        'audio: session started — capture ${inputRate.toStringAsFixed(0)}Hz, '
        'playback ${outputRate.toStringAsFixed(0)}Hz, '
        'wire ${kTxSampleRate}Hz/${kFrameSamples}smp frames, '
        'effectsSession=$sessionId, raw=$fmt',
      );

      _processor = AudioProcessor(sampleRate: kTxSampleRate.toDouble());
      _spectralSuppressor.reset();
      _rnnoiseSuppressor.reset();

      if (inputRate > kTxSampleRate) {
        _txLowPassA = OnePoleLowPass(
          sampleRate: inputRate,
          cutoffHz: kTxSampleRate * 0.45,
        );
        _txLowPassB = OnePoleLowPass(
          sampleRate: inputRate,
          cutoffHz: kTxSampleRate * 0.45,
        );
      } else {
        _txLowPassA = null;
        _txLowPassB = null;
      }
      _txResampler = LinearResampler(
        inRate: inputRate,
        outRate: kTxSampleRate.toDouble(),
      );
      _txAccum.clear();

      _rxResampler = LinearResampler(
        inRate: kTxSampleRate.toDouble(),
        outRate: outputRate,
      );

      final targetBufferMs = await _settingsRepository.getTargetBufferMs();
      // Already disposed at the top of this method, before the sink it writes
      // to was closed.
      _buffer = AudioPlaybackBuffer(
        output: _audioIo.output,
        sampleRate: outputRate.toInt(),
        targetBufferMs: targetBufferMs,
        debugLogging: true,
        outputUnderrunFrames: _audioIo.outputUnderrunFrames,
      );
    } catch (e) {
      Logger.log('AudioIo start error: $e');
      // Continue without crashing — processor stays default, buffer is null.
    }

    await _inputSub?.cancel();
    _inputSub = _audioIo.input.listen(
      _onInput,
      onError: (Object e) => Logger.log('AudioIo input error: $e'),
    );
    // Fresh streams — reset the stall clock so the watchdog gives them time
    // to start delivering before considering another restart.
    _lastInputAt = DateTime.now();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onInput(List<double> samples) {
    if (_frameController.isClosed) return;
    // Liveness heartbeat for the watchdog — any callback counts, even an
    // (unlikely) empty buffer means the capture stream is still alive.
    _lastInputAt = DateTime.now();
    if (samples.isEmpty) return;

    final resampler = _txResampler;
    if (resampler == null) return;

    _capCallbacks++;
    _capSamplesIn += samples.length;

    var filtered = _txLowPassA?.process(samples) ?? samples;
    filtered = _txLowPassB?.process(filtered) ?? filtered;
    final resampled = resampler.process(filtered);
    if (resampled.isEmpty) return;

    // `both` cascades rnnoise → spectral (rnnoise wants the raw-ish mic
    // signal it was trained on; spectral then mops up residual steady hum).
    // Wherever rnnoise isn't compiled in, `rnnoise` and `both` degrade to
    // spectral alone, matching the long-standing fallback.
    //
    // `off` is the one choice that degrades to nothing rather than to
    // spectral: a user who asked for no cleaning has not asked for a
    // different cleaner. Spelled out per-engine rather than as "!= x"
    // conditions — the negative form silently enrolled any newly added enum
    // value into both suppressors, which is exactly the bug `off` would have
    // hit.
    final engine = _suppressionEngine;
    final wantsRnnoise =
        engine == NoiseSuppressionEngine.rnnoise ||
        engine == NoiseSuppressionEngine.both;
    final useRnnoise = wantsRnnoise && _rnnoiseSuppressor.isAvailable;
    final useSpectral =
        engine == NoiseSuppressionEngine.spectral ||
        engine == NoiseSuppressionEngine.both ||
        (wantsRnnoise && !useRnnoise);
    var suppressed = resampled;
    if (useRnnoise) suppressed = _rnnoiseSuppressor.process(suppressed);
    if (useSpectral) suppressed = _spectralSuppressor.process(suppressed);
    _txAccum.addAll(suppressed);

    while (_txAccum.length >= kFrameSamples) {
      final frame = _txAccum.takeFirst(kFrameSamples);
      final rms = _computeRms(frame);
      _capFrames++;
      if (rms > _capPeakRms) _capPeakRms = rms;
      _capRmsSum += rms;
      _frameController.add(AudioFrame(rms: rms, samples: frame));
    }
    _logCaptureState();
  }

  // ── Capture diagnostics ────────────────────────────────────────────────────
  //
  // Before these, the entire microphone half of the pipeline was silent in the
  // exported log. A session where the mic delivered nothing, delivered silence,
  // or delivered at an unexpected rate looked exactly like a session where it
  // worked perfectly — and the only way to tell them apart was to ask the user
  // whether the other person could hear them.
  int _capCallbacks = 0;
  int _capSamplesIn = 0;
  int _capFrames = 0;
  double _capPeakRms = 0.0;
  double _capRmsSum = 0.0;
  DateTime _lastCaptureLogAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Matches the wifi transport's and the jitter buffer's period, so all three
  /// lines land together and a bad moment can be read across the whole
  /// pipeline at one timestamp.
  static const _captureLogInterval = Duration(seconds: 15);

  /// One line for the capture → filter → resample → suppress → frame stage.
  ///
  /// Rides the input callback rather than owning a timer: no callbacks means
  /// no mic, and a stage that has stopped delivering must not keep cheerfully
  /// printing that it is fine. (The stall watchdog covers the silence itself.)
  void _logCaptureState() {
    final now = DateTime.now();
    if (now.difference(_lastCaptureLogAt) < _captureLogInterval) return;
    final window = now.difference(_lastCaptureLogAt);
    _lastCaptureLogAt = now;
    final frames = _capFrames;
    // A first call after start would divide a full window's worth of counters
    // by an epoch-sized interval; skip it and report from the next one.
    if (window.inSeconds > 60) {
      _resetCaptureCounters();
      return;
    }
    final meanRms = frames == 0 ? 0.0 : _capRmsSum / frames;
    // Expected frame count for the elapsed time, so "the mic is delivering,
    // but at two thirds of real time" is visible as a number rather than as a
    // vague complaint that voices sound wrong.
    final expected =
        window.inMilliseconds * kTxSampleRate ~/ 1000 ~/ kFrameSamples;
    Logger.diagnostic(
      'capture: ${window.inSeconds}s window — callbacks=$_capCallbacks '
      'samplesIn=$_capSamplesIn frames=$frames/$expected '
      'peakRms=${_capPeakRms.toStringAsFixed(4)} '
      'meanRms=${meanRms.toStringAsFixed(4)} '
      'cleaner=${_suppressionEngine.name}'
      '${_rnnoiseSuppressor.isAvailable ? '' : ' (rnnoise unavailable)'}',
    );
    _resetCaptureCounters();
  }

  void _resetCaptureCounters() {
    _capCallbacks = 0;
    _capSamplesIn = 0;
    _capFrames = 0;
    _capPeakRms = 0.0;
    _capRmsSum = 0.0;
  }

  double _computeRms(List<double> samples) {
    if (samples.isEmpty) return 0.0;
    var sum = 0.0;
    for (var i = 0; i < samples.length; i++) {
      sum += samples[i] * samples[i];
    }
    return sqrt(sum / samples.length);
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _lastInputAt = DateTime.now();
    _lastWatchdogAt = DateTime.now();
    _watchdog = Timer.periodic(_kWatchdogInterval, (_) => _checkStall());
  }

  Future<void> _checkStall() async {
    // First, and on every path out of here: a stale [_lastWatchdogAt] would
    // itself read as a suspension the next time around.
    final now = DateTime.now();
    final sinceCheck = now.difference(_lastWatchdogAt);
    _lastWatchdogAt = now;

    // Time the isolate demonstrably did not run is time the mic was never
    // observed, so it cannot count toward a stall. Discounted precisely rather
    // than by a threshold: the mic is then given a full [_kStallTimeout] of
    // real, awake silence before the engine is touched — a genuine stall that
    // happens to straddle a resume is still caught, just one cycle later.
    final lateBy = sinceCheck - _kWatchdogInterval;
    if (lateBy > _kWatchdogJitter) {
      final credited = _lastInputAt.add(lateBy);
      _lastInputAt = credited.isAfter(now) ? now : credited;
    }

    if (_disposed || _restarting) return;
    if (_engineEpoch != _myEpoch) return; // a newer session owns the engine
    if (!_currentStatus.isStarted) return;
    if (now.difference(_lastInputAt) < _kStallTimeout) return;
    // Don't hammer restarts if reopening doesn't immediately deliver frames.
    if (now.difference(_lastRestartAt) < _kMinRestartInterval) return;

    _restarting = true;
    _lastRestartAt = now;
    // Diagnostic, not [log]: an engine restart closes and reopens the voice
    // streams, which is both an audible gap and — per this class's own notes on
    // media playback interrupting VOICE_COMMUNICATION — a plausible reason for
    // a media app to pause itself. A release log that cannot show when this
    // happened cannot answer "the music stopped on its own".
    Logger.diagnostic(
      'audio: input stalled ${now.difference(_lastInputAt).inMilliseconds}ms — restarting engine',
    );
    try {
      await _withEngineLock(() async {
        if (_disposed || _engineEpoch != _myEpoch) return;
        await _openStreams();
      });
    } finally {
      _restarting = false;
    }
  }

  void _watchRouteChanges() {
    _routeSub?.cancel();
    _routeSub = VoiceAudioSession.routeChanges.listen((_) => _scheduleReroute());
  }

  /// One headset lands as several device events (A2DP then SCO, capture and
  /// playback sides separately), so let a burst settle and re-open once.
  void _scheduleReroute() {
    if (_disposed) return;
    _routeSettle?.cancel();
    _routeSettle = Timer(_kRouteSettleDelay, _reopenForRoute);
  }

  Future<void> _reopenForRoute() async {
    if (_disposed) return;
    if (_engineEpoch != _myEpoch) return; // a newer session owns the engine
    if (!_currentStatus.isStarted) return;
    // A stall restart is already in flight — wait it out rather than dropping
    // the route change, which would strand the session on the wrong device.
    if (_restarting) {
      _scheduleReroute();
      return;
    }

    _restarting = true;
    // Counts as a restart for the watchdog: reopening resets the stall clock
    // anyway, and this keeps the two paths from stacking up on each other.
    _lastRestartAt = DateTime.now();
    // Diagnostic for the same reason as the stall restart above: this tears the
    // streams down and, on a Bluetooth route, cycles SCO — which stops A2DP
    // media on most phones.
    Logger.diagnostic('audio: route changed — reselecting device');
    try {
      await _withEngineLock(() async {
        if (_disposed || _engineEpoch != _myEpoch) return;
        await _openStreams(renegotiateRoute: true);
      });
    } finally {
      _restarting = false;
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  @override
  List<double> processForTransmit(List<double> samples, double voxThreshold) {
    _processor.gateThreshold = (voxThreshold * 0.5).clamp(0.0, 0.05);
    return _processor.process(samples);
  }

  @override
  void setNoiseSuppression(double strength) {
    final clamped = strength.clamp(0.0, 1.0);
    _spectralSuppressor.strength = clamped;
    _rnnoiseSuppressor.strength = clamped;
  }

  @override
  void setNoiseSuppressionEngine(NoiseSuppressionEngine engine) {
    if (engine == _suppressionEngine) return;
    _suppressionEngine = engine;
    // A suppressor that stops being called keeps whatever streaming state it
    // held — a spectral noise floor tracked minutes ago, an RNNoise FIFO still
    // carrying the samples it had not emitted yet. Switching back later would
    // then start from that stale state and produce a burst of wrongly-gained
    // or out-of-order audio on the first frames, which is precisely what the
    // user is listening for when they change the setting to compare.
    _spectralSuppressor.reset();
    _rnnoiseSuppressor.reset();
  }

  @override
  void playReceived(List<double> samples, int seq, String senderId) {
    // Emitted before resampling: this is the 16 kHz network frame, which is
    // what the visualizer wants — the speaker-rate copy is longer for no extra
    // detail. Fed straight out rather than through the jitter buffer, so the
    // dial tracks the wire and never waits on playback scheduling.
    // hasListener: with no visualizer mounted this is pure waste on the RX
    // hot path, and a broadcast controller drops the event anyway.
    if (_receivedFrameController.hasListener && samples.isNotEmpty) {
      _receivedFrameController.add(
        AudioFrame(rms: _computeRms(samples), samples: samples),
      );
    }
    final upsampled = _rxResampler?.process(samples) ?? samples;
    _buffer?.feed(upsampled, seq, senderId);
  }

  @override
  void resetPlayback() => _buffer?.reset();

  // ── dispose ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    // Flagged synchronously so an in-flight start() bails at its next
    // checkpoint instead of resurrecting the engine.
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
    _routeSettle?.cancel();
    _routeSettle = null;
    await _routeSub?.cancel();
    _routeSub = null;
    await _inputSub?.cancel();
    await _frameController.close();
    await _receivedFrameController.close();
    await _statusController.close();
    _buffer?.dispose();
    _rnnoiseSuppressor.dispose();
    // Epoch-guarded: if a newer session already claimed the engine (the
    // user re-entered the walkie page before this dispose chain finished),
    // leave it running for them instead of killing their session.
    await _stopEngineIfOwned();
  }
}
