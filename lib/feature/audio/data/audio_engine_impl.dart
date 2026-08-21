import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/audio/audio_format_profile.dart';
import '../../../core/settings/noise_suppression_engine.dart';
import '../../../core/settings/settings_repository.dart';
import '../../../core/settings/suppression_plan.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/permission_queue.dart';
import '../domain/audio_processor.dart';
import '../domain/entity/audio_engine_status.dart';
import '../domain/entity/audio_frame.dart';
import '../domain/float64_fifo.dart';
import '../domain/media_channel_converter.dart';
import '../domain/media_receive_buffer.dart';
import '../domain/playback_gain.dart';
import '../domain/resampler.dart';
import '../domain/rnnoise_suppressor.dart';
import '../domain/service/audio_engine.dart';
import '../domain/spectral_noise_suppressor.dart';
import '../domain/stall_watchdog.dart';
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

  // The wire-format contract this engine currently runs. Only ever changed by
  // [setWireFormat], once negotiation (`AudioCapabilityNegotiator`,
  // `feature/transfer`) has picked something other than the default.
  AudioFormatProfile _activeProfile = AudioFormatProfile.legacy16k;

  // Device rates the OS actually handed back, cached from the last
  // [_openStreams] so [setWireFormat] can rebuild the wire-format-dependent
  // half of the pipeline (see [_rebuildForFormat]) without re-querying
  // [_audioIo] — a format switch never needs to touch the device.
  double _inputRate = 48000.0;
  double _outputRate = 48000.0;

  AudioProcessor _processor = AudioProcessor(
    sampleRate: AudioFormatProfile.legacy16k.sampleRateHz.toDouble(),
  );

  // Noise suppression on the mic signal, applied BEFORE frames are emitted so
  // both the VOX RMS decision and the visualizer see the cleaned signal.
  // That's the point: with noise subtracted, a low VOX threshold no longer
  // keys up on noise. Two suppressors, user-selectable in Advanced settings
  // (either alone, or cascaded via NoiseSuppressionEngine.both) — both kept
  // warm (reset when idle costs nothing) so switching engines mid-session
  // doesn't need to rebuild anything. Reconstructed rather than reset by
  // [_rebuildForFormat] on a wire-format change: their internal sizing (the
  // spectral window, RNNoise's resample ratio) is fixed at construction.
  SpectralNoiseSuppressor _spectralSuppressor = SpectralNoiseSuppressor(
    sampleRateHz: AudioFormatProfile.legacy16k.sampleRateHz,
  );
  RnnoiseSuppressor _rnnoiseSuppressor = RnnoiseSuppressor(
    txRateHz: AudioFormatProfile.legacy16k.sampleRateHz,
  );
  NoiseSuppressionEngine _suppressionEngine = NoiseSuppressionEngine.spectral;
  double _suppressionStrength = 0.0;

  // Which cleaners run, and at what strength each. Rebuilt by
  // [_applySuppression] whenever one of its three inputs changes — never per
  // callback, which is where this branching used to live. The initial value is
  // the resolution of the two fields above (spectral, silent) written out,
  // since a field initialiser cannot read `_rnnoiseSuppressor`.
  SuppressionPlan _suppressionPlan = const SuppressionPlan(
    useRnnoise: false,
    rnnoiseStrength: 0.0,
    useSpectral: true,
    spectralStrength: 0.0,
  );

  // Survives _openStreams (which rebuilds _buffer on every route change), so a
  // gain set once at session start isn't silently reverted by a headset being
  // plugged in mid-ride.
  final PlaybackGain _playbackGain = PlaybackGain();

  AudioPlaybackBuffer? _buffer;

  // #30: Shared Music's own receive-side jitter buffer, independent of
  // [_buffer]'s (own queue, own per-sender sequence tracking, own
  // counters) — see [MediaReceiveBuffer]. Pull-based, mixed onto whatever
  // [_buffer] writes via [_MixingOutputSink] (built in [_openStreams]), plus
  // [_mediaCoordinatorTimer] for stretches where voice has nothing queued at
  // all and [_buffer]'s own drain timer is idle.
  MediaReceiveBuffer? _mediaBuffer;

  // Media's wire rate is fixed at 48 kHz for every negotiated profile
  // (AudioFormatProfile.media48kStereo/media48kMono), unlike voice's
  // [_rxResampler] which is rebuilt per negotiated profile — so this only
  // ever needs rebuilding when [_outputRate] itself changes (i.e. alongside
  // [_openStreams], same as [_rxResampler]).
  LinearResampler? _rxMediaResampler;

  Timer? _mediaCoordinatorTimer;

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
  static const _stallWatchdog = StallWatchdog(
    stallTimeout: _kStallTimeout,
    minRestartInterval: _kMinRestartInterval,
    watchdogInterval: _kWatchdogInterval,
    watchdogJitter: _kWatchdogJitter,
  );

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

  // TX path: device mic rate → anti-alias filter → _activeProfile's rate →
  // fixed-size frames. Two cascaded one-pole stages give a steeper
  // (~12 dB/octave) rolloff than a single stage, which matters here: a gentle
  // single-pole filter lets energy above the new Nyquist fold back as audible
  // hiss/noise when downsampling from 44.1/48 kHz to the wire rate.
  OnePoleLowPass? _txLowPassA;
  OnePoleLowPass? _txLowPassB;
  LinearResampler? _txResampler;
  final Float64Fifo _txAccum = Float64Fifo();

  // RX path: network audio at _activeProfile's rate → device output rate.
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
      _mediaCoordinatorTimer?.cancel();
      _mediaCoordinatorTimer = null;
      _mediaBuffer?.dispose();
      _mediaBuffer = null;
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
      _inputRate = (fmt?['input']?['sampleRate'] as num?)?.toDouble() ?? 48000.0;
      _outputRate =
          (fmt?['output']?['sampleRate'] as num?)?.toDouble() ?? _inputRate;
      // Diagnostic, not debug: the rates the OS actually handed us decide
      // every resampler ratio downstream, and a device that negotiates
      // something unexpected (16 kHz capture over a Bluetooth headset, a
      // 44.1 kHz output) changes how the whole pipeline sounds. Reported
      // once per session start, where a fault is either present or absent —
      // and previously only on a debug build, i.e. never on the phone that
      // had the problem.
      Logger.diagnostic(
        'audio: session started — capture ${_inputRate.toStringAsFixed(0)}Hz, '
        'playback ${_outputRate.toStringAsFixed(0)}Hz, '
        'effectsSession=$sessionId, raw=$fmt',
      );

      _rebuildForFormat(_activeProfile);

      // Via the profile, not getTargetBufferMs(): the riding preset anchors
      // the adaptive buffer deeper, and reading the raw preference here would
      // apply the preset to the VOX gate and the cleaner but not to the one
      // knob that decides whether a link between two moving bikes stutters.
      final profile = await _settingsRepository.getAudioProfile();
      _playbackGain.gain = profile.playbackGain;
      // Already disposed at the top of this method, before the sink it writes
      // to was closed.
      //
      // #30: voice writes through [_MixingOutputSink] rather than straight to
      // [_audioIo.output] — it pulls a same-length media frame (if any) each
      // time voice writes and sums it in before the one real write. See that
      // class and [_mediaCoordinatorTimer] for the stretches voice writes
      // nothing at all.
      _mediaBuffer = MediaReceiveBuffer(sampleRate: _outputRate.toInt());
      _rxMediaResampler = LinearResampler(inRate: 48000, outRate: _outputRate);
      _buffer = AudioPlaybackBuffer(
        output: _MixingOutputSink(_audioIo.output, () => _mediaBuffer),
        sampleRate: _outputRate.toInt(),
        targetBufferMs: profile.targetBufferMs,
        debugLogging: true,
        outputUnderrunFrames: _audioIo.outputUnderrunFrames,
      );
      _mediaCoordinatorTimer = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => _mediaCoordinatorTick(),
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

  /// Rebuilds everything downstream of the wire-format contract: the
  /// processor/suppressor chain, the TX anti-alias filters and resampler
  /// (and its accumulator), and the RX resampler. Never touches [_audioIo],
  /// [VoiceAudioSession], or route selection — a wire-format switch is a
  /// hot-swap of the pipeline between the already-open device and the
  /// already-open jitter buffer, not a device reopen, which is what keeps
  /// [setWireFormat] from being able to cause a screen-off disconnect or a
  /// route-change deadlock: there is no device teardown in this method for
  /// either of those to happen to.
  ///
  /// Shared by [_openStreams] (where [_inputRate]/[_outputRate] were just
  /// freshly queried) and [setWireFormat] (where they're whatever
  /// [_openStreams] last found), so both paths build this half of the
  /// pipeline identically.
  void _rebuildForFormat(AudioFormatProfile profile) {
    final profileRate = profile.sampleRateHz.toDouble();
    Logger.diagnostic(
      'audio: wire format ${profile.label} — '
      '${profile.sampleRateHz}Hz/${profile.frameSamples}smp frames '
      '(capture ${_inputRate.toStringAsFixed(0)}Hz, '
      'playback ${_outputRate.toStringAsFixed(0)}Hz)',
    );

    _processor = AudioProcessor(sampleRate: profileRate);
    // Reconstructed, not reset: each one's internal sizing (the spectral
    // window, RNNoise's up/down resample ratio) is fixed at construction and
    // depends on this rate. The old RNNoise instance holds native denoiser
    // state that [reset] doesn't free — only [dispose] does.
    _spectralSuppressor = SpectralNoiseSuppressor(
      sampleRateHz: profile.sampleRateHz,
    );
    _rnnoiseSuppressor.dispose();
    _rnnoiseSuppressor = RnnoiseSuppressor(txRateHz: profile.sampleRateHz);
    // After the suppressors are rebuilt, not before: rnnoise's construction
    // re-probes native availability, so the plan can change here.
    _applySuppression();

    if (_inputRate > profileRate) {
      _txLowPassA = OnePoleLowPass(
        sampleRate: _inputRate,
        cutoffHz: profileRate * 0.45,
      );
      _txLowPassB = OnePoleLowPass(
        sampleRate: _inputRate,
        cutoffHz: profileRate * 0.45,
      );
    } else {
      _txLowPassA = null;
      _txLowPassB = null;
    }
    _txResampler = LinearResampler(inRate: _inputRate, outRate: profileRate);
    _txAccum.clear();

    _rxResampler = LinearResampler(inRate: profileRate, outRate: _outputRate);
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

    // `both` cascades rnnoise → spectral (rnnoise wants the raw-ish mic signal
    // it was trained on; spectral then mops up residual steady hum, at a
    // reduced strength so the two don't compound). Which stages run and how
    // hard is decided by [SuppressionPlan], not here — see [_applySuppression].
    final plan = _suppressionPlan;
    var suppressed = resampled;
    if (plan.useRnnoise) suppressed = _rnnoiseSuppressor.process(suppressed);
    if (plan.useSpectral) suppressed = _spectralSuppressor.process(suppressed);
    _txAccum.addAll(suppressed);

    final frameSamples = _activeProfile.frameSamples;
    while (_txAccum.length >= frameSamples) {
      final frame = _txAccum.takeFirst(frameSamples);
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
        window.inMilliseconds *
        _activeProfile.sampleRateHz ~/
        1000 ~/
        _activeProfile.frameSamples;
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
    // itself read as a suspension the next time around. The discounting math
    // itself — crediting time the isolate demonstrably did not run so it
    // can't count toward a stall — lives in [StallWatchdog], pure and
    // independently tested.
    final now = DateTime.now();
    final result = _stallWatchdog.check(
      now: now,
      lastInputAt: _lastInputAt,
      lastWatchdogAt: _lastWatchdogAt,
      lastRestartAt: _lastRestartAt,
    );
    _lastWatchdogAt = now;
    _lastInputAt = result.creditedInputAt;

    if (_disposed || _restarting) return;
    if (_engineEpoch != _myEpoch) return; // a newer session owns the engine
    if (!_currentStatus.isStarted) return;
    // Don't hammer restarts if reopening doesn't immediately deliver frames,
    // and don't restart at all unless a real, cooled-down stall was found.
    if (!result.shouldRestart) return;

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
    _routeSub = VoiceAudioSession.routeChanges.listen(
      (_) => _scheduleReroute(),
    );
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
  void setWireFormat(AudioFormatProfile profile) {
    if (profile == _activeProfile) return;
    _activeProfile = profile;
    _rebuildForFormat(profile);
  }

  @override
  List<double> processForTransmit(List<double> samples, double voxLevel) {
    // Half the gate's own level, so the expander only trims residual noise
    // inside frames VOX has already decided are speech — it must never be the
    // thing deciding. Capped, because this level now follows the measured
    // background and a loud room could otherwise push a *within-frame*
    // expander up to where it chews quiet syllables.
    _processor.gateThreshold = (voxLevel * 0.5).clamp(0.0, 0.05);
    return _processor.process(samples);
  }

  @override
  void setNoiseSuppression(double strength) {
    _suppressionStrength = strength.clamp(0.0, 1.0);
    _applySuppression();
  }

  /// Re-resolves the plan from its three inputs — the selected engine, the
  /// user's strength, and whether the native denoiser loaded — and pushes the
  /// per-engine strengths into the suppressors.
  ///
  /// Availability is read here rather than cached because [RnnoiseSuppressor]
  /// gets a fresh denoiser probe on a session restart ([RnnoiseSuppressor.reset])
  /// and on a wire-format switch ([_rebuildForFormat] reconstructs it), so
  /// either is a moment it can change.
  void _applySuppression() {
    final plan = SuppressionPlan.resolve(
      engine: _suppressionEngine,
      strength: _suppressionStrength,
      rnnoiseAvailable: _rnnoiseSuppressor.isAvailable,
    );
    _suppressionPlan = plan;
    _spectralSuppressor.strength = plan.spectralStrength;
    _rnnoiseSuppressor.strength = plan.rnnoiseStrength;
  }

  @override
  void setPlaybackGain(double gain) => _playbackGain.gain = gain;

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
    _applySuppression();
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
    // Gain last, after the visualizer tap above has already taken its copy:
    // the dial should show what arrived on the wire, not what this listener
    // chose to turn up. Both stages pass their argument straight through at
    // their no-op setting, so a session with neither a resampler nor a gain
    // hands the buffer the caller's own list — which is why nothing here may
    // write into a list in place.
    final upsampled = _rxResampler?.process(samples) ?? samples;
    _buffer?.feed(_playbackGain.apply(upsampled), seq, senderId);
  }

  @override
  void playReceivedMedia(
    List<double> samples,
    int channels,
    int seq,
    String senderId,
  ) {
    // Downmixed before resampling — cheaper (half the samples through the
    // resampler) and order-independent, since averaging L/R and linear
    // resampling both commute over a stream with no other processing
    // between them.
    final mono = channels == 2
        ? MediaChannelConverter.downmixToMono(samples)
        : samples;
    final upsampled = _rxMediaResampler?.process(mono) ?? mono;
    _mediaBuffer?.feed(upsampled, seq, senderId);
  }

  /// Writes media directly to the real output for stretches where [_buffer]
  /// has nothing queued at all and its own drain timer is idle — see
  /// [MediaReceiveBuffer]'s class doc. A no-op the overwhelming majority of
  /// ticks: [_buffer.isDraining] true (voice is playing, [_MixingOutputSink]
  /// already covers this tick) or [_mediaBuffer] has nothing ready (no music
  /// cast active) are both cheap early-outs.
  void _mediaCoordinatorTick() {
    if (_buffer?.isDraining ?? false) return;
    final media = _mediaBuffer?.pullFrame(_outputRate.toInt() * 10 ~/ 1000);
    if (media == null) return;
    _audioIo.output.add(media);
  }

  @override
  void resetPlayback() {
    _buffer?.reset();
    _mediaBuffer?.reset();
  }

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
    _mediaCoordinatorTimer?.cancel();
    _mediaCoordinatorTimer = null;
    _mediaBuffer?.dispose();
    _mediaBuffer = null;
    _rnnoiseSuppressor.dispose();
    // Epoch-guarded: if a newer session already claimed the engine (the
    // user re-entered the walkie page before this dispose chain finished),
    // leave it running for them instead of killing their session.
    await _stopEngineIfOwned();
  }
}

/// Wraps the real output sink so [AudioPlaybackBuffer] (voice) can go on
/// writing exactly as it always has, while every write also carries
/// whatever Shared Music (#30) has ready — see [MediaReceiveBuffer] and
/// [AudioEngineImpl._mediaCoordinatorTick] for why this has to be a mix
/// at voice's own write point rather than a second independent writer:
/// two unsynchronized timers both calling `add` on the same output sink
/// would interleave two unrelated PCM streams, not mix them.
class _MixingOutputSink implements Sink<List<double>> {
  _MixingOutputSink(this._real, this._mediaBuffer);

  final Sink<List<double>> _real;

  /// A closure rather than a captured reference: [AudioEngineImpl] rebuilds
  /// [AudioEngineImpl._mediaBuffer] on every [AudioEngineImpl._openStreams]
  /// call (route changes), and this sink must always read whichever instance
  /// is current rather than one frozen at construction time.
  final MediaReceiveBuffer? Function() _mediaBuffer;

  @override
  void add(List<double> data) {
    final media = _mediaBuffer()?.pullFrame(data.length);
    if (media == null) {
      _real.add(data);
      return;
    }
    final mixed = Float64List(data.length);
    for (var i = 0; i < data.length; i++) {
      mixed[i] = (data[i] + media[i]).clamp(-1.0, 1.0);
    }
    _real.add(mixed);
  }

  @override
  void close() => _real.close();
}
