import 'dart:async';
import 'dart:math';

import 'package:audio_io/audio_io.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/utils/logger.dart';
import '../../data/audio_playback_buffer.dart';
import '../../domain/audio_processor.dart';
import '../../domain/entity/audio_frame.dart';
import '../../domain/resampler.dart';

// ── Wire format constants ───────────────────────────────────────────────────

/// Sample rate audio is transmitted at. 16 kHz is plenty for intelligible
/// voice (telephony-grade) and keeps bandwidth + per-packet size low so
/// packets never fragment on the wire — the main source of dropouts when
/// streaming raw mic-rate audio over UDP.
const int kTxSampleRate = 16000;

/// 20 ms per network frame: 320 samples @ 16 kHz × 2 bytes (PCM16) = 640
/// bytes of payload, safely under the ~1472-byte UDP-safe MTU even with
/// headers — guarantees one frame == one unfragmented IP packet.
const int kFrameSamples = 320;

// ── State ────────────────────────────────────────────────────────────────────

class AudioStatus extends Equatable {
  final bool hasPermission;
  final bool isStarted;

  const AudioStatus({
    required this.hasPermission,
    required this.isStarted,
  });

  factory AudioStatus.initial() =>
      const AudioStatus(hasPermission: true, isStarted: false);

  @override
  List<Object?> get props => [hasPermission, isStarted];
}

// ── Cubit ────────────────────────────────────────────────────────────────────

@injectable
class AudioCubit extends Cubit<AudioStatus> {
  AudioCubit(this._audioIo) : super(AudioStatus.initial());

  final AudioIo _audioIo;

  // ── Engine ownership ───────────────────────────────────────────────────
  // AudioIo is a process-wide singleton, but AudioCubit instances come and
  // go with the walkie page — and BlocProvider disposes the old cubit
  // WITHOUT awaiting its close(). A stale close() can therefore still be
  // running (its awaits can lag by seconds) when the next page's cubit
  // starts the engine. Two static guards make that safe:
  //  * _engineLock serializes stop/start transitions. audio_io's FFI layer
  //    wedges permanently if they interleave: its stop() clears the running
  //    flag, suspends on controller closes, then destroys whatever handle
  //    the singleton currently holds — which by then is the handle a
  //    concurrent start() just created — while start() has already set the
  //    running flag back to true, so every later start() no-ops forever.
  //  * _engineEpoch tracks which cubit session owns the engine, so a stale
  //    close() skips its stop instead of killing the newer session's mic.
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
      });

  AudioProcessor _processor = AudioProcessor(sampleRate: kTxSampleRate.toDouble());
  AudioPlaybackBuffer? _buffer;
  StreamSubscription<List<double>>? _inputSub;
  final StreamController<AudioFrame> _frameController =
      StreamController<AudioFrame>.broadcast();

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

  /// Audio-rate stream of fixed-size (20 ms @ 16 kHz) outgoing frames —
  /// subscribe with a StreamBuilder or listen directly.
  Stream<AudioFrame> get frames => _frameController.stream;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> start() async {
    // Claim engine ownership synchronously, before the first await: any
    // stale close() that runs from here on sees a newer epoch and won't
    // stop the engine out from under this session.
    _myEpoch = ++_engineEpoch;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (!isClosed) {
        emit(const AudioStatus(hasPermission: false, isStarted: false));
      }
      return;
    }

    var started = false;
    await _withEngineLock(() async {
      // Superseded by a newer session, or closed while waiting for the
      // permission dialog / lock — the engine belongs to someone else now.
      if (_engineEpoch != _myEpoch || isClosed) return;

      try {
        await _audioIo.stop();
        await _audioIo.requestLatency(AudioIoLatency.Balanced);
        try {
          await _audioIo.start();
        } catch (_) {
          // Re-opening the duplex device right after a teardown can fail
          // transiently on some Android devices — give it one more chance.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await _audioIo.start();
        }
        final fmt = await _audioIo.getFormat();
        Logger.log('AudioIo format: $fmt');
        final inputRate =
            (fmt?['input']?['sampleRate'] as num?)?.toDouble() ?? 48000.0;
        final outputRate =
            (fmt?['output']?['sampleRate'] as num?)?.toDouble() ?? inputRate;

        _processor = AudioProcessor(sampleRate: kTxSampleRate.toDouble());

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

    if (isClosed) {
      // close() ran while we were starting — shut the engine back down.
      await _inputSub?.cancel();
      await _stopEngineIfOwned();
      return;
    }
    if (started) {
      emit(const AudioStatus(hasPermission: true, isStarted: true));
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

    _txAccum.addAll(resampled);

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

  /// Apply the audio processing chain (normalisation + high-pass + noise
  /// gate) to a fixed-size 16 kHz mic frame before it is transmitted.
  ///
  /// [voxThreshold] ties the internal noise gate to the user's VOX setting:
  /// it scales down as the VOX threshold is lowered and disables entirely
  /// at 0, so a VOX threshold of "0 = always on" truly means no gating
  /// anywhere in the chain (not just at the frame level).
  List<double> processForTransmit(List<double> samples, double voxThreshold) {
    _processor.gateThreshold = (voxThreshold * 0.5).clamp(0.0, 0.05);
    return _processor.process(samples);
  }

  /// Feed received network audio (16 kHz PCM) into the jitter buffer,
  /// upsampling to the device's output rate first.
  /// [seq] is the sender's packet sequence number and [senderId] identifies
  /// which peer sent it — the jitter buffer tracks sequence gaps per sender
  /// so one participant's stream can't desync playback of another's (a WiFi
  /// channel can have more than 2 participants).
  void playReceived(List<double> samples, int seq, String senderId) {
    final upsampled = _rxResampler?.process(samples) ?? samples;
    _buffer?.feed(upsampled, seq, senderId);
  }

  // ── close ──────────────────────────────────────────────────────────────────

  @override
  Future<void> close() async {
    await _inputSub?.cancel();
    await _frameController.close();
    _buffer?.dispose();
    // Epoch-guarded: if a newer AudioCubit already claimed the engine (the
    // user re-entered the walkie page before this close chain finished),
    // leave it running for them instead of killing their session.
    await _stopEngineIfOwned();
    return super.close();
  }
}
