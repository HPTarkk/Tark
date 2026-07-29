import 'dart:async';
import 'dart:ffi';
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

  Future<void> start() async {
    if (_isRunning) return;

    _handle = _bindings.create();
    if (_handle == nullptr) {
      throw Exception('Failed to create audio context');
    }

    // Set the frame duration before starting
    _bindings.setFrameDuration(_handle!, _requestedFrameDuration);

    final result = _bindings.start(_handle!);
    if (result != 0) {
      _bindings.destroy(_handle!);
      _handle = null;
      throw Exception('Failed to start audio device');
    }

    _isRunning = true;

    _readScratch = malloc<Double>(_kFramesPerPoll);

    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();

    _outputController!.stream.listen((data) {
      _writeAudio(data);
    });

    _startInputPolling();
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    _inputTimer?.cancel();
    _inputTimer = null;

    await _inputController?.close();
    await _outputController?.close();
    _inputController = null;
    _outputController = null;

    if (_handle != null) {
      _bindings.stop(_handle!);
      _bindings.destroy(_handle!);
      _handle = null;
    }

    // Freed only after the timer is cancelled and the controllers are
    // closed, so no in-flight poll or write can still be holding them.
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
