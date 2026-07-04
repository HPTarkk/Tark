import 'dart:async';
import 'dart:math';

import 'package:audio_io/audio_io.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/utils/logger.dart';
import '../domain/audio_processor.dart';
import '../domain/entity/audio_engine_status.dart';
import '../domain/entity/audio_frame.dart';
import '../domain/resampler.dart';
import '../domain/service/audio_engine.dart';
import '../domain/spectral_noise_suppressor.dart';
import 'audio_playback_buffer.dart';
import 'voice_audio_session.dart';

@Injectable(as: AudioEngine)
class AudioEngineImpl implements AudioEngine {
  AudioEngineImpl(this._audioIo);

  final AudioIo _audioIo;

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

  AudioProcessor _processor =
      AudioProcessor(sampleRate: kTxSampleRate.toDouble());

  // Spectral noise suppression on the 16 kHz mic signal, applied BEFORE
  // frames are emitted so both the VOX RMS decision and the visualizer see
  // the cleaned signal. That's the point: with stationary noise (wind,
  // engine) subtracted, a low VOX threshold no longer keys up on noise.
  final SpectralNoiseSuppressor _suppressor = SpectralNoiseSuppressor();

  AudioPlaybackBuffer? _buffer;
  StreamSubscription<List<double>>? _inputSub;
  final StreamController<AudioFrame> _frameController =
      StreamController<AudioFrame>.broadcast();

  bool _disposed = false;
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
  final List<double> _txAccum = [];

  // RX path: 16 kHz network audio → device output rate.
  LinearResampler? _rxResampler;

  @override
  Stream<AudioFrame> get frames => _frameController.stream;

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
      micGranted = (await Permission.microphone.request()).isGranted;
    } catch (e) {
      Logger.log('Mic permission request unavailable: $e');
    }
    if (!micGranted) {
      if (!_disposed) {
        _setStatus(
            const AudioEngineStatus(hasPermission: false, isStarted: false));
      }
      return;
    }

    var started = false;
    await _withEngineLock(() async {
      // Superseded by a newer session, or disposed while waiting for the
      // permission dialog / lock — the engine belongs to someone else now.
      if (_engineEpoch != _myEpoch || _disposed) return;

      try {
        await _audioIo.stop();
        // Android: bring the Bluetooth SCO route up — and confirmed — BEFORE
        // the engine opens its streams. Older devices don't re-route streams
        // that are already open (Galaxy S8 + AirPods went silent both ways).
        // No-op without a BT headset; rolls itself back if SCO fails so the
        // default route keeps working.
        await VoiceAudioSession.configure();
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
        final fmt = await _audioIo.getFormat();
        Logger.log('AudioIo format: $fmt');
        final inputRate =
            (fmt?['input']?['sampleRate'] as num?)?.toDouble() ?? 48000.0;
        final outputRate =
            (fmt?['output']?['sampleRate'] as num?)?.toDouble() ?? inputRate;

        _processor = AudioProcessor(sampleRate: kTxSampleRate.toDouble());
        _suppressor.reset();

        if (inputRate > kTxSampleRate) {
          _txLowPassA = OnePoleLowPass(
              sampleRate: inputRate, cutoffHz: kTxSampleRate * 0.45);
          _txLowPassB = OnePoleLowPass(
              sampleRate: inputRate, cutoffHz: kTxSampleRate * 0.45);
        } else {
          _txLowPassA = null;
          _txLowPassB = null;
        }
        _txResampler = LinearResampler(
            inRate: inputRate, outRate: kTxSampleRate.toDouble());
        _txAccum.clear();

        _rxResampler = LinearResampler(
            inRate: kTxSampleRate.toDouble(), outRate: outputRate);

        _buffer?.dispose();
        _buffer = AudioPlaybackBuffer(
          output: _audioIo.output,
          sampleRate: outputRate.toInt(),
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
      started = true;
    });

    if (_disposed) {
      // dispose() ran while we were starting — shut the engine back down.
      await _inputSub?.cancel();
      await _stopEngineIfOwned();
      return;
    }
    if (started) {
      _setStatus(
          const AudioEngineStatus(hasPermission: true, isStarted: true));
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onInput(List<double> samples) {
    if (_frameController.isClosed || samples.isEmpty) return;

    final resampler = _txResampler;
    if (resampler == null) return;

    var filtered = _txLowPassA?.process(samples) ?? samples;
    filtered = _txLowPassB?.process(filtered) ?? filtered;
    final resampled = resampler.process(filtered);
    if (resampled.isEmpty) return;

    _txAccum.addAll(_suppressor.process(resampled));

    while (_txAccum.length >= kFrameSamples) {
      final frame = _txAccum.sublist(0, kFrameSamples);
      _txAccum.removeRange(0, kFrameSamples);
      final rms = _computeRms(frame);
      _frameController.add(AudioFrame(rms: rms, samples: frame));
    }
  }

  double _computeRms(List<double> samples) {
    if (samples.isEmpty) return 0.0;
    final sum = samples.fold<double>(0.0, (acc, s) => acc + s * s);
    return sqrt(sum / samples.length);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  @override
  List<double> processForTransmit(List<double> samples, double voxThreshold) {
    _processor.gateThreshold = (voxThreshold * 0.5).clamp(0.0, 0.05);
    return _processor.process(samples);
  }

  @override
  void setNoiseSuppression(double strength) {
    _suppressor.strength = strength.clamp(0.0, 1.0);
  }

  @override
  void playReceived(List<double> samples, int seq, String senderId) {
    final upsampled = _rxResampler?.process(samples) ?? samples;
    _buffer?.feed(upsampled, seq, senderId);
  }

  // ── dispose ────────────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    // Flagged synchronously so an in-flight start() bails at its next
    // checkpoint instead of resurrecting the engine.
    _disposed = true;
    await _inputSub?.cancel();
    await _frameController.close();
    await _statusController.close();
    _buffer?.dispose();
    // Epoch-guarded: if a newer session already claimed the engine (the
    // user re-entered the walkie page before this dispose chain finished),
    // leave it running for them instead of killing their session.
    await _stopEngineIfOwned();
  }
}
