import 'dart:async';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/core/settings/audio_profile.dart';
import 'package:tark/core/settings/noise_suppression_engine.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/utils/logger.dart';
import 'package:tark/feature/audio/data/audio_engine_impl.dart';
import 'package:tark/feature/audio/domain/entity/audio_frame.dart';
import 'package:tark/feature/audio/domain/resampler.dart';

const _profile = AudioProfile(
  voxMargin: 0,
  noiseSuppression: 0,
  noiseSuppressionEngine: NoiseSuppressionEngine.spectral,
  targetBufferMs: 60,
  playbackGain: 1,
  fromPreset: false,
);

class _Settings implements SettingsRepository {
  AudioProfile profile = _profile;
  bool failProfileRead = false;
  Completer<AudioProfile>? pendingProfile;
  final profileRequested = Completer<void>();

  @override
  Future<AudioProfile> getAudioProfile() async {
    if (!profileRequested.isCompleted) profileRequested.complete();
    if (failProfileRead) throw StateError('Settings read failed');
    return pendingProfile == null ? profile : await pendingProfile!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

mixin _TrackedProcessor {
  bool disposed = false;
  int disposeCount = 0;
  int resetCount = 0;

  void checkAlive() {
    if (disposed) throw StateError('Test processor is disposed');
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    disposeCount++;
  }
}

class _Resampler with _TrackedProcessor implements RealtimeResampler {
  _Resampler(double inputRate, double outputRate)
    : delegate = LinearResampler(inRate: inputRate, outRate: outputRate);
  final LinearResampler delegate;

  @override
  Float64List process(List<double> samples) {
    checkAlive();
    return delegate.process(samples);
  }

  @override
  void reset() {
    checkAlive();
    resetCount++;
    delegate.reset();
  }
}

class _LowPass with _TrackedProcessor implements RealtimeLowPass {
  @override
  Float64List process(List<double> samples) {
    checkAlive();
    return Float64List.fromList(samples);
  }

  @override
  void reset() => checkAlive();
}

class _Spectral with _TrackedProcessor implements RealtimeSpectralSuppressor {
  @override
  double strength = 0;

  @override
  Float64List process(List<double> samples) {
    checkAlive();
    return Float64List.fromList(samples);
  }

  @override
  void reset() {
    checkAlive();
    resetCount++;
  }
}

class _RecordingSink implements Sink<List<double>> {
  _RecordingSink(this.onWrite);
  final void Function(List<double>) onWrite;

  @override
  void add(List<double> samples) => onWrite(samples);
  @override
  void close() {}
}

class _VoiceQueue implements VoiceQueue {
  final writes = <Float64List>[];
  int target = 0;
  int resets = 0;
  @override
  int queuedFrames = 0;
  @override
  bool isPlaying = false;
  @override
  int underruns = 0;
  @override
  int starvedFrames = 0;
  @override
  int playedFrames = 0;
  @override
  int trims = 0;
  @override
  int jumps = 0;
  @override
  int deviceBurstFrames = 240;

  @override
  int write(Float64List samples) {
    writes.add(Float64List.fromList(samples));
    queuedFrames += samples.length;
    return samples.length;
  }

  @override
  int writeSilence(int count) {
    queuedFrames += count;
    return count;
  }

  @override
  set targetFrames(int value) => target = value;

  @override
  void reset() {
    resets++;
    queuedFrames = 0;
    isPlaying = false;
  }
}

class _AudioIo extends AudioIo {
  final capture = StreamController<List<double>>.broadcast(sync: true);
  final playback = StreamController<List<double>>.broadcast();
  final processors = <_TrackedProcessor>[];
  final playedBlocks = <List<double>>[];
  _VoiceQueue? nativeQueue;
  int queuedOutputFrames = -1;
  int inputRate = 48000;
  int outputRate = 48000;
  int sessionId = -1;
  int starts = 0;
  int stops = 0;
  bool running = false;
  int remainingStartFailures = 0;
  bool throwOnStop = false;
  bool failNextResampler = false;
  bool supportsDsp = true;

  int get liveProcessors => processors.where((p) => !p.disposed).length;

  @override
  Stream<List<double>> get input => capture.stream;
  late final Sink<List<double>> _output = _RecordingSink((samples) {
    playedBlocks.add(List<double>.of(samples));
    if (queuedOutputFrames >= 0) queuedOutputFrames += samples.length;
    playback.add(samples);
  });
  @override
  Sink<List<double>> get output => _output;
  @override
  VoiceQueue? get voiceQueue => nativeQueue;
  @override
  int outputUnderrunFrames() => 0;
  @override
  int outputQueuedFrames() => queuedOutputFrames;

  @override
  Future<void> start() async {
    starts++;
    if (remainingStartFailures > 0) {
      remainingStartFailures--;
      throw StateError('Device start failed');
    }
    running = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
    if (throwOnStop) throw StateError('Device stop failed');
  }

  @override
  Future<void> requestLatency(AudioIoLatency option) async {}
  @override
  Future<int> inputSessionId() async => sessionId;
  @override
  Future<Map<String, dynamic>?> getFormat() async => {
    'input': {'sampleRate': inputRate},
    'output': {'sampleRate': outputRate},
  };

  @override
  RealtimeResampler? createRealtimeResampler(double inRate, double outRate) {
    if (failNextResampler) {
      failNextResampler = false;
      throw StateError('Native resampler allocation failed');
    }
    if (!supportsDsp) return null;
    final processor = _Resampler(inRate, outRate);
    processors.add(processor);
    return processor;
  }

  @override
  RealtimeLowPass? createRealtimeLowPass(double sampleRate, double cutoffHz) {
    if (!supportsDsp) return null;
    final processor = _LowPass();
    processors.add(processor);
    return processor;
  }

  @override
  RealtimeSpectralSuppressor? createRealtimeSpectralSuppressor(int sampleRate) {
    if (!supportsDsp) return null;
    final processor = _Spectral();
    processors.add(processor);
    return processor;
  }

  Future<void> closeTestStreams() async {
    await capture.close();
    await playback.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const voice = MethodChannel('tark/audio_session');
  const events = MethodChannel('tark/audio_session/events');
  late List<String> voiceCalls;
  late List<String> logLines;

  setUp(() {
    voiceCalls = [];
    logLines = [];
    Logger.sink = logLines.add;
    messenger.setMockMethodCallHandler(
      permissions,
      (call) async => {
        for (final permission in call.arguments as List<dynamic>)
          permission as int: 1,
      },
    );
    messenger.setMockMethodCallHandler(voice, (call) async {
      voiceCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() {
    Logger.sink = null;
    messenger.setMockMethodCallHandler(permissions, null);
    messenger.setMockMethodCallHandler(voice, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<void> waitUntil(bool Function() ready) async {
    final deadline = Stopwatch()..start();
    while (!ready()) {
      if (deadline.elapsed > const Duration(seconds: 3)) {
        fail('Audio output or lifecycle transition did not arrive');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void feedMedia(
    AudioEngineImpl engine, {
    bool stereo = false,
    int firstSeq = 0,
  }) {
    for (var seq = firstSeq; seq < firstSeq + 7; seq++) {
      final samples = stereo
          ? List<double>.generate(1920, (i) => i.isEven ? 0.2 : 0.4)
          : List<double>.filled(960, 0.3);
      engine.playReceivedMedia(samples, stereo ? 2 : 1, seq, 'music');
    }
  }

  test(
    'dispose before start creates no DSP and rejects later processing',
    () async {
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      final first = engine.dispose();
      expect(identical(first, engine.dispose()), isTrue);
      await first;
      expect(io.processors, isEmpty);
      expect(io.stops, 0);
      expect(engine.start(), throwsStateError);
      expect(() => engine.processForTransmit([0.1], 0), throwsStateError);
      expect(
        () => engine.setWireFormat(AudioFormatProfile.hd24k),
        throwsStateError,
      );
      await io.closeTestStreams();
    },
  );

  test(
    'dispose during settings await releases every in-flight DSP handle',
    () async {
      final io = _AudioIo();
      final settings = _Settings()..pendingProfile = Completer<AudioProfile>();
      final engine = AudioEngineImpl(io, settings);
      final starting = engine.start();
      await settings.profileRequested.future;
      expect(io.liveProcessors, 5);
      final disposing = engine.dispose();
      settings.pendingProfile!.complete(_profile);
      await Future.wait([starting, disposing]);
      expect(io.liveProcessors, 0);
      expect(io.processors.every((p) => p.disposeCount == 1), isTrue);
      expect(io.running, isFalse);
      expect(engine.currentStatus.isStarted, isFalse);
      await io.closeTestStreams();
    },
  );

  test(
    'failed device retry reports stopped and releases the voice session',
    () async {
      final io = _AudioIo()..remainingStartFailures = 2;
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      expect(io.starts, 2);
      expect(io.running, isFalse);
      expect(engine.currentStatus.isStarted, isFalse);
      expect(voiceCalls, contains('releaseVoice'));
      expect(io.liveProcessors, 0);
      // Failed startup must keep the settings controls usable; disposed native
      // suppressors must not be reset or mutated by a later settings push.
      engine.setNoiseSuppression(0.5);
      engine.setNoiseSuppressionEngine(NoiseSuppressionEngine.both);
      engine.setNoiseSuppressionEngine(NoiseSuppressionEngine.spectral);
      expect(io.liveProcessors, 0);
      await engine.start();
      expect(engine.currentStatus.isStarted, isTrue);
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'failed format allocation preserves the previous working pipeline',
    () async {
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      final frames = <AudioFrame>[];
      final subscription = engine.frames.listen(frames.add);
      await engine.start();
      final previous = List<_TrackedProcessor>.of(io.processors);
      expect(io.liveProcessors, 6);
      io.failNextResampler = true;
      expect(
        () => engine.setWireFormat(AudioFormatProfile.hd24k),
        throwsStateError,
      );
      expect(io.liveProcessors, 6);
      expect(previous.every((p) => !p.disposed), isTrue);
      expect(
        io.processors.skip(previous.length).every((p) => p.disposed),
        isTrue,
      );
      io.capture.add(List<double>.filled(960, 0.1));
      await Future<void>.delayed(Duration.zero);
      expect(frames.single.samples, hasLength(320));
      engine.setWireFormat(AudioFormatProfile.hd24k);
      expect(previous.take(5).every((p) => p.disposed), isTrue);
      frames.clear();
      io.capture.add(List<double>.filled(960, 0.1));
      await Future<void>.delayed(Duration.zero);
      expect(frames.single.samples, hasLength(480));
      expect(io.starts, 1, reason: 'Format swaps must not reopen the device');
      await subscription.cancel();
      await engine.dispose();
      expect(io.liveProcessors, 0);
      await io.closeTestStreams();
    },
  );

  test('a stale dispose leaves the newer session running', () async {
    final io = _AudioIo();
    final old = AudioEngineImpl(io, _Settings());
    await old.start();
    final newer = AudioEngineImpl(io, _Settings());
    await newer.start();
    final stopsBefore = io.stops;
    await old.dispose();
    expect(io.running, isTrue);
    expect(io.stops, stopsBefore);
    expect(newer.currentStatus.isStarted, isTrue);
    expect(io.liveProcessors, 6);
    await newer.dispose();
    expect(io.liveProcessors, 0);
    await io.closeTestStreams();
  });

  test(
    'a teardown error still frees DSP and releases the voice session',
    () async {
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      io.throwOnStop = true;
      await expectLater(engine.dispose(), throwsStateError);
      expect(io.liveProcessors, 0);
      expect(voiceCalls.last, 'releaseVoice');
      await expectLater(engine.frames.toList(), completion(isEmpty));
      await io.closeTestStreams();
    },
  );

  test('unsupported DSP factories use the Dart capture fallback', () async {
    final io = _AudioIo()..supportsDsp = false;
    final engine = AudioEngineImpl(io, _Settings());
    final frames = <AudioFrame>[];
    final subscription = engine.frames.listen(frames.add);
    engine.setNoiseSuppression(0.5);
    await engine.start();
    io.capture.add(List<double>.filled(960, 0.1));
    await Future<void>.delayed(Duration.zero);
    expect(engine.currentStatus.isStarted, isTrue);
    expect(io.processors, isEmpty);
    expect(frames.single.samples, hasLength(320));
    await subscription.cancel();
    await engine.dispose();
    await io.closeTestStreams();
  });

  test(
    'permission denial publishes the denial without opening a device',
    () async {
      messenger.setMockMethodCallHandler(
        permissions,
        (call) async => {
          for (final permission in call.arguments as List<dynamic>)
            permission as int: 0,
        },
      );
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      expect(engine.currentStatus.hasPermission, isFalse);
      expect(engine.currentStatus.isStarted, isFalse);
      expect(io.starts, 0);
      expect(io.processors, isEmpty);
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'a missing permission backend defers to the audio device prompt',
    () async {
      messenger.setMockMethodCallHandler(permissions, (_) async {
        throw MissingPluginException('No permission backend on this platform');
      });
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      expect(io.starts, 1);
      expect(engine.currentStatus.hasPermission, isTrue);
      expect(engine.currentStatus.isStarted, isTrue);
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'a settings read error closes the already-created capture pipeline',
    () async {
      final io = _AudioIo();
      final settings = _Settings()..failProfileRead = true;
      final engine = AudioEngineImpl(io, settings);
      await engine.start();
      expect(io.processors, hasLength(5));
      expect(io.liveProcessors, 0);
      expect(io.running, isFalse);
      expect(engine.currentStatus.isStarted, isFalse);
      settings.failProfileRead = false;
      await engine.start();
      expect(engine.currentStatus.isStarted, isTrue);
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'received voice keeps raw visualizer PCM separate from playback gain',
    () async {
      final io = _AudioIo()..nativeQueue = _VoiceQueue();
      final engine = AudioEngineImpl(io, _Settings());
      final frames = <AudioFrame>[];
      final subscription = engine.receivedFrames.listen(frames.add);
      await engine.start();
      engine.setPlaybackGain(2);
      final incoming = List<double>.filled(320, 0.2);
      engine.playReceived(incoming, 0, 'voice');
      engine.playReceived([], 1, 'empty');
      await waitUntil(() => frames.isNotEmpty);
      expect(frames.single.samples, orderedEquals(incoming));
      expect(frames.single.rms, closeTo(0.2, 1e-12));
      expect(incoming.every((sample) => sample == 0.2), isTrue);
      final queued = io.nativeQueue!.writes.expand((block) => block).toList();
      expect(queued, isNotEmpty);
      expect(queued.reduce((a, b) => a > b ? a : b), closeTo(0.4, 1e-12));
      expect(io.nativeQueue!.target, 2880);
      expect(
        io.playedBlocks,
        isEmpty,
        reason: 'Voice goes directly to native queue',
      );
      await subscription.cancel();
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'media-only stereo downmix ducks for sustained local speech and resets',
    () async {
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      engine.setLocalVoiceActive(true);
      feedMedia(engine, stereo: true);
      await waitUntil(() => io.playedBlocks.length >= 12);
      expect(io.playedBlocks.first, hasLength(480));
      expect(io.playedBlocks.first.last, closeTo(0.3, 1e-12));
      expect(io.playedBlocks.last.last, lessThan(0.2));
      expect(
        logLines.where((line) => line.contains('normal -> ducked')),
        hasLength(1),
      );
      engine.setLocalVoiceActive(false);
      engine.resetPlayback();
      final blocksBefore = io.playedBlocks.length;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(io.playedBlocks, hasLength(blocksBefore));
      feedMedia(engine, firstSeq: 0);
      await waitUntil(() => io.playedBlocks.length > blocksBefore);
      expect(io.playedBlocks[blocksBefore].last, closeTo(0.3, 1e-12));
      expect(
        logLines.where((line) => line.contains('ducked -> normal')),
        hasLength(1),
      );
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'voice and media share one output stream and clamp summed peaks',
    () async {
      final io = _AudioIo();
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      engine.setSmartMusicDuckingEnabled(false);
      feedMedia(engine);
      for (var seq = 0; seq < 4; seq++) {
        engine.playReceived(List<double>.filled(320, 0.2), seq, 'voice');
      }
      await waitUntil(
        () => io.playedBlocks.any(
          (block) => block.any((sample) => sample >= 0.5),
        ),
      );
      expect(io.playedBlocks, isNotEmpty);
      final mixed = io.playedBlocks.expand((block) => block).toList();
      expect(mixed.reduce((a, b) => a > b ? a : b), closeTo(0.5, 1e-12));
      // The independent media timer must not write a second PCM stream while
      // the voice jitter buffer is draining through the mixing sink.
      expect(io.playedBlocks.first, hasLength(1440));
      expect(
        io.playedBlocks.skip(1).every((block) => block.length == 480),
        isTrue,
      );
      engine.resetPlayback();
      io.playedBlocks.clear();
      for (var seq = 0; seq < 7; seq++) {
        engine.playReceivedMedia(
          List<double>.filled(960, 0.8),
          1,
          seq,
          'music',
        );
      }
      for (var seq = 0; seq < 4; seq++) {
        engine.playReceived(List<double>.filled(320, 0.8), seq, 'voice');
      }
      await waitUntil(
        () => io.playedBlocks.any((block) => block.contains(1.0)),
      );
      final peaks = io.playedBlocks.expand((block) => block).toList();
      expect(peaks, isNotEmpty);
      expect(peaks.every((value) => value >= -1 && value <= 1), isTrue);
      expect(peaks, contains(1.0));
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'native media refills the measured ring and ducks for remote speech',
    () async {
      final io = _AudioIo()..nativeQueue = _VoiceQueue();
      final engine = AudioEngineImpl(io, _Settings());
      await engine.start();
      io.nativeQueue!.isPlaying = true;
      feedMedia(engine);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        io.playedBlocks,
        isEmpty,
        reason: 'Unknown ring depth cannot be topped up',
      );
      io.queuedOutputFrames = 0;
      await waitUntil(() => io.playedBlocks.length >= 5);
      expect(io.playedBlocks, hasLength(5));
      expect(io.queuedOutputFrames, 2400);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        io.playedBlocks,
        hasLength(5),
        reason: 'A full ring must not be overfed',
      );
      io.queuedOutputFrames = 0;
      await waitUntil(() => io.playedBlocks.length >= 10);
      expect(io.playedBlocks, hasLength(10));
      expect(io.playedBlocks.first.last, closeTo(0.3, 1e-12));
      expect(io.playedBlocks.last.last, lessThan(0.3));
      engine.setSmartMusicDuckingEnabled(false);
      feedMedia(engine, firstSeq: 7);
      io.queuedOutputFrames = 0;
      await waitUntil(() => io.playedBlocks.length >= 15);
      expect(io.playedBlocks.last.last, closeTo(0.3, 1e-12));
      final resetCount = io.nativeQueue!.resets;
      engine.resetPlayback();
      expect(io.nativeQueue!.resets, resetCount + 1);
      expect(io.nativeQueue!.queuedFrames, 0);
      await engine.dispose();
      await io.closeTestStreams();
    },
  );

  test(
    'a route burst rebuilds once at the new device rates and preserves capture',
    () async {
      late MockStreamHandlerEventSink routeEvents;
      messenger.setMockStreamHandler(
        const EventChannel('tark/audio_session/events'),
        MockStreamHandler.inline(onListen: (_, sink) => routeEvents = sink),
      );
      final io = _AudioIo()
        ..nativeQueue = _VoiceQueue()
        ..sessionId = 42;
      final engine = AudioEngineImpl(io, _Settings());
      final captured = <AudioFrame>[];
      final subscription = engine.frames.listen(captured.add);
      await engine.start();
      final previous = List<_TrackedProcessor>.of(io.processors);
      expect(voiceCalls, contains('attachEffects'));
      io.inputRate = 16000;
      io.outputRate = 24000;
      for (var i = 0; i < 3; i++) {
        routeEvents.success(null);
        await Future<void>.delayed(Duration.zero);
      }
      expect(io.starts, 1);
      await waitUntil(
        () =>
            io.starts == 2 &&
            io.liveProcessors == 4 &&
            previous.every((processor) => processor.disposed),
      );
      expect(io.starts, 2);
      expect(
        voiceCalls.where((call) => call == 'reconfigureVoice'),
        hasLength(1),
      );
      expect(previous.every((processor) => processor.disposed), isTrue);
      expect(
        io.liveProcessors,
        4,
        reason: '16k capture does not need anti-alias filters',
      );
      expect(
        io.nativeQueue!.target,
        1440,
        reason: 'Playback target follows 24k output',
      );
      io.capture.add([]);
      io.capture.add([0.15]);
      io.capture.add(List<double>.filled(640, 0.15));
      await waitUntil(() => captured.length == 2);
      expect(captured, hasLength(2));
      expect(captured.every((frame) => frame.samples.length == 320), isTrue);
      expect(captured.first.rms, closeTo(0.15, 1e-12));
      engine.setNoiseSuppressionEngine(NoiseSuppressionEngine.both);
      expect(io.processors.whereType<_Spectral>().last.resetCount, 1);
      await subscription.cancel();
      await engine.dispose();
      await io.closeTestStreams();
      expect(io.liveProcessors, 0);
    },
  );
}
