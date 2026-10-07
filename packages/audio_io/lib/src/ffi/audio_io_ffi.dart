import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../device_call_limit.dart';
import '../voice_queue.dart';
import '../realtime_dsp.dart';
import 'audio_io_bindings.dart';

/// Size of the persistent read scratch buffer, so a poll never needs to
/// allocate. Matches the native input ring (RING_BUFFER_SIZE in
/// audio_io_miniaudio.cpp), so one poll can always empty it.
///
/// It used to be 480 — exactly one 10 ms tick of audio — and each poll read
/// at most that much. Dart skips a periodic timer's missed ticks rather than
/// replaying them, so every poll that ran more than 10 ms late left 10 ms
/// behind in the ring that no later poll could ever catch up on. Capture
/// delay crept up by one tick per hiccup until the ring was full (170 ms),
/// and from then on the audio thread dropped whatever did not fit — a hole in
/// the speaker's voice that the listener heard as a tick.
const int _kFramesPerPoll = 8192;

/// How long a device start may take on its helper isolate. A healthy one
/// returns in well under a second, including the retry inside miniaudio.
const Duration _kStartLimit = Duration(seconds: 6);

/// How long a device teardown may take. miniaudio's own wait for pending
/// reroute jobs is capped at 2 s, so anything past this is stuck for good.
const Duration _kTeardownLimit = Duration(seconds: 4);

class AudioIoFFI {
  static AudioIoFFI? _instance;
  static AudioIoFFI get instance => _instance ??= AudioIoFFI._();

  late final AudioIoBindings _bindings;
  Pointer<Void>? _handle;

  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;

  // Native scratch buffers, allocated once per session rather than per call.
  // The poll runs 100x/second on the UI isolate and the write side runs at
  // playback rate, so malloc/free churn here is pure overhead.
  Pointer<Double>? _readScratch;
  Pointer<Double>? _writeScratch;
  int _writeScratchFrames = 0;

  Timer? _inputTimer;

  bool _isRunning = false;
  double _requestedFrameDuration = 0.003; // Default to Balanced (3ms)

  AudioIoFFI._() {
    _bindings = AudioIoBindings();
  }

  Stream<List<double>>? get inputAudioStream => _inputController?.stream;
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  // Serializes [start] and [stop]. There is one native device behind this
  // singleton, and both calls now suspend (the device work happens on a helper
  // isolate — see below), so without this a stop() that is still tearing the
  // old device down could overlap a start() that has already created the new
  // one: two duplex AAudio devices alive at once, and whichever teardown
  // finishes last frees a handle the other one is using. Callers happen to
  // serialize this today, but the singleton owns the handle, so the guarantee
  // belongs here rather than in every caller.
  Future<void> _lifecycle = Future<void>.value();

  Future<void> _serializeLifecycle(Future<void> Function() action) {
    final run = _lifecycle.then((_) => action());
    // The chain must survive a failed start (which throws) or every later
    // start/stop would be skipped.
    _lifecycle = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  // ── Device lifecycle runs off the calling thread ──────────────────────────
  //
  // FFI calls execute on the calling thread, and Flutter's Dart UI thread IS
  // Android's main thread here — the process has `1.raster` and `1.io` but no
  // separate `1.ui`. So a blocking device call is not merely jank, it is an
  // app-wide ANR.
  //
  // Both directions block for real: ma_device_start__aaudio() and
  // ma_device_uninit() take AAudio's rerouteLock and join miniaudio's threads,
  // and a route change landing inside AAudio's start handshake could wedge the
  // teardown permanently (see the LOCAL PATCH notes in miniaudio.h — a
  // speakerphone switch during start froze a Galaxy S8+ with the main thread
  // parked in pthread_join under ma_device_uninit). Running them on a helper
  // isolate degrades that worst case from "whole app freezes" to "audio does
  // not come up", which the stall watchdog can then recover from.
  //
  // create + setFrameDuration + start are one hop so the ordering can't be
  // split, and a failed start disposes the handle there rather than handing
  // back something the caller would have to tear down on the main thread.
  //
  // "Audio does not come up" was still not recoverable, though: a call that
  // never returns held [_lifecycle], so every later start and stop waited on
  // it forever. Both calls are therefore time-limited (see
  // [limitDeviceCall]). A stuck device is abandoned on its isolate and the
  // next start opens a fresh one.

  /// Whether this engine has closed the devices an earlier one left open.
  /// Done once, before its first device: until then nothing open in this
  /// process can be this engine's.
  static bool _leftoversReleased = false;

  /// Returns the device handle address, or 0 if the device could not start,
  /// and how many devices an earlier engine had left running.
  ///
  /// The native library lives as long as the process, which can outlast the
  /// Flutter engine that loaded it: Android may destroy the app's screen and
  /// keep the process (the app swiped away during a call, then reopened).
  /// The old engine's device then keeps running with no Dart side, and keeps
  /// the microphone, so this one could never open its own. Seen on a Galaxy
  /// S8 (Android 9): every start after reopening failed until the app was
  /// killed.
  static Future<(int, int)> _createAndStartDevice(
    double frameDuration, {
    required bool releaseLeftovers,
  }) {
    return Isolate.run(() {
      final bindings = AudioIoBindings();
      final leftovers = releaseLeftovers ? bindings.releaseAll?.call() ?? 0 : 0;
      final handle = bindings.create();
      if (handle == nullptr) return (0, leftovers);

      bindings.setFrameDuration(handle, frameDuration);
      if (bindings.start(handle) != 0) {
        bindings.destroy(handle);
        return (0, leftovers);
      }
      return (handle.address, leftovers);
    });
  }

  static Future<void> _stopAndDestroyDevice(int handleAddress) {
    return Isolate.run(() {
      final bindings = AudioIoBindings();
      final handle = Pointer<Void>.fromAddress(handleAddress);
      bindings.stop(handle);
      bindings.destroy(handle);
    });
  }

  Future<void> start() => _serializeLifecycle(_start);

  Future<void> stop() => _serializeLifecycle(_stop);

  Future<void> _start() async {
    if (_isRunning) return;

    final releaseLeftovers = !_leftoversReleased;
    _leftoversReleased = true;
    final (handleAddress, leftovers) = await limitDeviceCall(
      _createAndStartDevice(
        _requestedFrameDuration,
        releaseLeftovers: releaseLeftovers,
      ),
      limit: _kStartLimit,
      onTimeout: () {
        AudioIoDiagnostics.report(
          'audio_io: device start did not return in '
          '${_kStartLimit.inSeconds}s — abandoned it',
        );
        return (0, 0);
      },
      // Came up after we gave up on it: nobody holds this handle, so close it.
      onLate: (late) {
        if (late.$1 != 0) {
          unawaited(_stopAndDestroyDevice(late.$1).catchError((Object _) {}));
        }
      },
    );
    if (leftovers > 0) {
      AudioIoDiagnostics.report(
        'audio_io: closed $leftovers device(s) an earlier run of the app '
        'left open',
      );
    }
    if (handleAddress == 0) {
      throw Exception('Failed to start audio device');
    }
    _handle = Pointer<Void>.fromAddress(handleAddress);

    _isRunning = true;

    _readScratch = malloc<Double>(_kFramesPerPoll);

    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();

    _outputController!.stream.listen((data) {
      _writeAudio(data);
    });

    _startInputPolling();
  }

  Future<void> _stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    _inputTimer?.cancel();
    _inputTimer = null;

    await _inputController?.close();
    await _outputController?.close();
    _inputController = null;
    _outputController = null;

    // Detached before the await below, so a poll or write that somehow still
    // runs sees null and bails instead of using a handle that is being torn
    // down — and so a start() racing this teardown can't have its fresh
    // handle clobbered by this continuation.
    final handle = _handle;
    _handle = null;

    // Freed only after the timer is cancelled and the controllers are
    // closed, so no in-flight poll or write can still be holding them. Done
    // before the teardown await rather than after, so these can't be freed
    // out from under a start() that has already reallocated them.
    final readScratch = _readScratch;
    if (readScratch != null) {
      malloc.free(readScratch);
      _readScratch = null;
    }
    final writeScratch = _writeScratch;
    if (writeScratch != null) {
      malloc.free(writeScratch);
      _writeScratch = null;
      _writeScratchFrames = 0;
    }

    // Native teardown last, and off this thread — see _stopAndDestroyDevice.
    if (handle != null) {
      await limitDeviceCall<void>(
        _stopAndDestroyDevice(handle.address),
        limit: _kTeardownLimit,
        onTimeout: () => AudioIoDiagnostics.report(
          'audio_io: device teardown did not return in '
          '${_kTeardownLimit.inSeconds}s — abandoned it',
        ),
      );
    }
  }

  void _startInputPolling() {
    const pollInterval = Duration(milliseconds: 10);

    _inputTimer = Timer.periodic(pollInterval, (_) {
      if (!_isRunning || _handle == null) return;
      final scratch = _readScratch;
      if (scratch == null) return;

      final availableFrames = _bindings.getAvailableReadFrames(_handle!);
      if (availableFrames <= 0) return;

      final framesToRead =
          availableFrames > _kFramesPerPoll ? _kFramesPerPoll : availableFrames;
      final framesRead = _bindings.read(_handle!, scratch, framesToRead);
      if (framesRead <= 0) return;

      // Emit unboxed samples. `List<double>.generate` here allocated one
      // boxed double per sample — 48k heap objects a second, all of it
      // garbage the moment the frame is consumed — and every downstream
      // read of the result paid an unbox. asTypedList views the native
      // memory directly, and the copy out is a memmove.
      //
      // The copy is not optional: the scratch buffer is overwritten by the
      // next poll, while listeners on this broadcast stream may still hold
      // the previous chunk.
      final data = Float64List(framesRead)
        ..setAll(0, scratch.asTypedList(framesRead));
      _inputController?.add(data);
    });
  }

  void _writeAudio(List<double> data) {
    if (!_isRunning || _handle == null || data.isEmpty) return;

    // Grow the scratch buffer only when a larger block shows up; playback
    // block sizes are stable in practice, so this settles after the first.
    if (_writeScratchFrames < data.length) {
      final existing = _writeScratch;
      // Clear the field before freeing: if the allocation below throws, the
      // stale pointer must not be left behind for the next call to use.
      _writeScratch = null;
      _writeScratchFrames = 0;
      if (existing != null) malloc.free(existing);
      _writeScratch = malloc<Double>(data.length);
      _writeScratchFrames = data.length;
    }

    final scratch = _writeScratch!;
    final view = scratch.asTypedList(data.length);
    if (data is Float64List) {
      view.setAll(0, data); // memmove
    } else {
      for (int i = 0; i < data.length; i++) {
        view[i] = data[i];
      }
    }

    _bindings.write(_handle!, scratch, data.length);
  }

  Map<String, dynamic> getFormat() {
    if (_handle == null) {
      return {
        'input': {
          'type': 'double',
          'channels': 1,
          'sampleRate': 48000.0,
        },
        'output': {
          'type': 'double',
          'channels': 1,
          'sampleRate': 48000.0,
        },
      };
    }

    final sampleRate = _bindings.getSampleRate(_handle!).toDouble();
    final channels = _bindings.getChannels(_handle!);

    return {
      'input': {
        'type': 'double',
        'channels': channels,
        'sampleRate': sampleRate,
      },
      'output': {
        'type': 'double',
        'channels': channels,
        'sampleRate': sampleRate,
      },
    };
  }

  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;
    if (_handle != null) {
      _bindings.setFrameDuration(_handle!, duration);
    }
  }

  Future<double> getFrameDuration() async {
    if (_handle != null) {
      return _bindings.getFrameDuration(_handle!);
    }
    return 0.01;
  }

  /// AAudio capture session id for attaching platform voice effects, or -1
  /// when unavailable. Valid only while the device is running.
  int getInputSessionId() {
    if (_handle == null) return -1;
    return _bindings.getInputSessionId(_handle!);
  }

  /// Cumulative frames the playback callback filled with silence for want of
  /// data. Resets with the device handle, so it counts within a session.
  int getOutputUnderrunFrames() {
    if (_handle == null) return 0;
    return _bindings.getOutputUnderrunFrames(_handle!);
  }

  /// The native received-voice queue. Always the current device's: every
  /// call resolves the handle afresh, and does nothing without one.
  late final VoiceQueue voiceQueue = _FfiVoiceQueue(this);

  /// Samples in the output ring the device has not played yet, or -1 with no
  /// device. Counts only what has reached the ring: [outputAudioStream]
  /// delivers asynchronously, so a write made this same event-loop turn is
  /// not included yet.
  int getOutputQueuedFrames() {
    if (_handle == null) return -1;
    return _bindings.getOutputQueuedFrames(_handle!);
  }
}

class _FfiVoiceQueue implements VoiceQueue {
  _FfiVoiceQueue(this._ffi);

  final AudioIoFFI _ffi;

  Pointer<Double>? _scratch;
  int _scratchFrames = 0;

  @override
  int write(Float64List samples) {
    final handle = _ffi._handle;
    if (handle == null || samples.isEmpty) return 0;
    if (_scratchFrames < samples.length) {
      final old = _scratch;
      _scratch = null;
      _scratchFrames = 0;
      if (old != null) malloc.free(old);
      _scratch = malloc<Double>(samples.length);
      _scratchFrames = samples.length;
    }
    final scratch = _scratch!;
    scratch.asTypedList(samples.length).setAll(0, samples);
    return _ffi._bindings.voiceWrite(handle, scratch, samples.length);
  }

  @override
  int writeSilence(int count) {
    final handle = _ffi._handle;
    if (handle == null || count <= 0) return 0;
    return _ffi._bindings.voiceWriteZeros(handle, count);
  }

  @override
  set targetFrames(int frames) {
    final handle = _ffi._handle;
    if (handle != null) _ffi._bindings.voiceSetTarget(handle, frames);
  }

  @override
  void reset() {
    final handle = _ffi._handle;
    if (handle != null) _ffi._bindings.voiceReset(handle);
  }

  int _stat(int which) {
    final handle = _ffi._handle;
    if (handle == null) return 0;
    final v = _ffi._bindings.voiceStat(handle, which);
    return v < 0 ? 0 : v;
  }

  @override
  int get queuedFrames => _stat(0);
  @override
  bool get isPlaying => _stat(1) == 1;
  @override
  int get underruns => _stat(2);
  @override
  int get starvedFrames => _stat(3);
  @override
  int get playedFrames => _stat(4);
  @override
  int get trims => _stat(5);
  @override
  int get jumps => _stat(6);
  @override
  int get deviceBurstFrames => _stat(7);
}


class FfiRealtimeResampler implements RealtimeResampler {
  FfiRealtimeResampler._(this._bindings, this._handle);

  factory FfiRealtimeResampler.create(
    AudioIoBindings bindings,
    double inRate,
    double outRate,
  ) {
    final handle = bindings.resamplerCreate(inRate, outRate);
    if (handle == nullptr) {
      throw StateError('Failed to create native realtime resampler');
    }
    return FfiRealtimeResampler._(bindings, handle);
  }

  final AudioIoBindings _bindings;
  Pointer<Void> _handle;
  Pointer<Double>? _input;
  Pointer<Double>? _output;
  int _inputCapacity = 0;
  int _outputCapacity = 0;

  void _ensureInput(int frames) {
    if (_inputCapacity >= frames) return;
    final old = _input;
    if (old != null) malloc.free(old);
    _input = malloc<Double>(frames);
    _inputCapacity = frames;
  }

  void _ensureOutput(int frames) {
    if (_outputCapacity >= frames) return;
    final old = _output;
    if (old != null) malloc.free(old);
    _output = malloc<Double>(frames);
    _outputCapacity = frames;
  }

  @override
  Float64List process(List<double> samples) {
    if (_handle == nullptr || samples.isEmpty) return Float64List(0);
    _ensureInput(samples.length);
    final input = _input!;
    final inView = input.asTypedList(samples.length);
    if (samples is Float64List) {
      inView.setAll(0, samples);
    } else {
      for (var i = 0; i < samples.length; i++) {
        inView[i] = samples[i];
      }
    }

    final capacity = _bindings.resamplerOutputCapacity(
      _handle,
      samples.length,
    );
    if (capacity <= 0) return Float64List(0);
    _ensureOutput(capacity);
    final written = _bindings.resamplerProcess(
      _handle,
      input,
      samples.length,
      _output!,
      capacity,
    );
    if (written <= 0) return Float64List(0);
    return Float64List.fromList(_output!.asTypedList(written));
  }

  @override
  void reset() {
    if (_handle != nullptr) _bindings.resamplerReset(_handle);
  }

  @override
  void dispose() {
    if (_handle != nullptr) {
      _bindings.resamplerDestroy(_handle);
      _handle = nullptr;
    }
    final input = _input;
    if (input != null) malloc.free(input);
    _input = null;
    _inputCapacity = 0;
    final output = _output;
    if (output != null) malloc.free(output);
    _output = null;
    _outputCapacity = 0;
  }
}

class FfiRealtimeLowPass implements RealtimeLowPass {
  FfiRealtimeLowPass._(this._bindings, this._handle);

  factory FfiRealtimeLowPass.create(
    AudioIoBindings bindings,
    double sampleRate,
    double cutoffHz,
  ) {
    final handle = bindings.lowPassCreate(sampleRate, cutoffHz);
    if (handle == nullptr) {
      throw StateError('Failed to create native realtime low-pass');
    }
    return FfiRealtimeLowPass._(bindings, handle);
  }

  final AudioIoBindings _bindings;
  Pointer<Void> _handle;
  Pointer<Double>? _input;
  Pointer<Double>? _output;
  int _capacity = 0;

  void _ensureCapacity(int frames) {
    if (_capacity >= frames) return;
    final input = _input;
    if (input != null) malloc.free(input);
    final output = _output;
    if (output != null) malloc.free(output);
    _input = malloc<Double>(frames);
    _output = malloc<Double>(frames);
    _capacity = frames;
  }

  @override
  Float64List process(List<double> samples) {
    if (_handle == nullptr || samples.isEmpty) return Float64List(0);
    _ensureCapacity(samples.length);
    final inView = _input!.asTypedList(samples.length);
    if (samples is Float64List) {
      inView.setAll(0, samples);
    } else {
      for (var i = 0; i < samples.length; i++) {
        inView[i] = samples[i];
      }
    }
    _bindings.lowPassProcess(_handle, _input!, _output!, samples.length);
    return Float64List.fromList(_output!.asTypedList(samples.length));
  }

  @override
  void reset() {
    if (_handle != nullptr) _bindings.lowPassReset(_handle);
  }

  @override
  void dispose() {
    if (_handle != nullptr) {
      _bindings.lowPassDestroy(_handle);
      _handle = nullptr;
    }
    final input = _input;
    if (input != null) malloc.free(input);
    _input = null;
    final output = _output;
    if (output != null) malloc.free(output);
    _output = null;
    _capacity = 0;
  }
}
