import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'audio_io_bindings.dart';

/// Frames pulled per poll — also the size of the persistent read scratch
/// buffer, so a poll never needs to allocate.
const int _kFramesPerPoll = 480;

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

  /// Returns the device handle address, or 0 if the device could not start.
  static Future<int> _createAndStartDevice(double frameDuration) {
    return Isolate.run(() {
      final bindings = AudioIoBindings();
      final handle = bindings.create();
      if (handle == nullptr) return 0;

      bindings.setFrameDuration(handle, frameDuration);
      if (bindings.start(handle) != 0) {
        bindings.destroy(handle);
        return 0;
      }
      return handle.address;
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

    final handleAddress = await _createAndStartDevice(_requestedFrameDuration);
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
      await _stopAndDestroyDevice(handle.address);
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

      final framesToRead = availableFrames > _kFramesPerPoll
          ? _kFramesPerPoll
          : availableFrames;
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
}
