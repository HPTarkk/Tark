import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/entity/audio_engine_status.dart';
import 'package:tark/feature/audio/domain/entity/audio_frame.dart';
import 'package:tark/feature/audio/domain/entity/audio_route.dart';
import 'package:tark/feature/audio/domain/service/audio_engine.dart';
import 'package:tark/feature/preflight/data/mic_probe.dart';

/// Minimal test double for the whole-of-[AudioEngine] interface.
///
/// `implements` plus a forwarding [noSuchMethod] is deliberate here: 15 of
/// [AudioEngine]'s members are irrelevant to [MicProbe] (wire format,
/// noise suppression, ducking, playback...), and stubbing every one of them
/// would bury the three that matter (`start`, `currentStatus`, `frames`,
/// `dispose`) under boilerplate no test here exercises.
class _FakeAudioEngine implements AudioEngine {
  _FakeAudioEngine({required this.statusAfterStart, this.frameToEmit});

  final AudioEngineStatus statusAfterStart;
  final AudioFrame? frameToEmit;

  bool started = false;
  bool disposed = false;

  @override
  Future<void> start() async => started = true;

  @override
  AudioEngineStatus get currentStatus => statusAfterStart;

  @override
  Stream<AudioFrame> get frames =>
      frameToEmit == null ? const Stream.empty() : Stream.value(frameToEmit!);

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AudioRoute> _fakeRoute(AudioRoute route) async => route;

void main() {
  test('permission denied is reported without waiting for a frame', () async {
    final engine = _FakeAudioEngine(
      statusAfterStart: const AudioEngineStatus(
        hasPermission: false,
        isStarted: false,
      ),
    );

    final result = await MicProbe.run(resolveEngine: () => engine);

    expect(result.outcome, MicProbeOutcome.permissionDenied);
    expect(
      result.route,
      AudioRoute.unknown,
      reason: 'start() never reached configureVoice on this branch',
    );
    expect(engine.started, isTrue);
    expect(engine.disposed, isTrue, reason: 'the probe engine must not leak');
  });

  test(
    'engine started but no frame within the window reports noFrames',
    () async {
      final engine = _FakeAudioEngine(
        statusAfterStart: const AudioEngineStatus(
          hasPermission: true,
          isStarted: true,
        ),
        frameToEmit: null,
      );

      final result = await MicProbe.run(
        resolveEngine: () => engine,
        resolveRoute: () => _fakeRoute(AudioRoute.unknown),
        timeout: const Duration(milliseconds: 50),
      );

      expect(result.outcome, MicProbeOutcome.noFrames);
      expect(engine.disposed, isTrue);
    },
  );

  test('a real frame arriving within the window reports ok', () async {
    final engine = _FakeAudioEngine(
      statusAfterStart: const AudioEngineStatus(
        hasPermission: true,
        isStarted: true,
      ),
      frameToEmit: const AudioFrame(rms: 0.2, samples: [0.1, 0.2]),
    );

    final result = await MicProbe.run(
      resolveEngine: () => engine,
      resolveRoute: () => _fakeRoute(AudioRoute.unknown),
    );

    expect(result.outcome, MicProbeOutcome.ok);
    expect(engine.disposed, isTrue);
  });

  test(
    'the route is queried on this same probe session, before dispose '
    'releases it — and handed back alongside the frame outcome',
    () async {
      final engine = _FakeAudioEngine(
        statusAfterStart: const AudioEngineStatus(
          hasPermission: true,
          isStarted: true,
        ),
        frameToEmit: const AudioFrame(rms: 0.2, samples: [0.1, 0.2]),
      );

      final result = await MicProbe.run(
        resolveEngine: () => engine,
        resolveRoute: () => _fakeRoute(AudioRoute.bluetoothHeadset),
      );

      expect(result.outcome, MicProbeOutcome.ok);
      expect(result.route, AudioRoute.bluetoothHeadset);
    },
  );

  test('the probe engine is disposed on every outcome, never left running', () async {
    for (final engine in [
      _FakeAudioEngine(
        statusAfterStart: const AudioEngineStatus(
          hasPermission: false,
          isStarted: false,
        ),
      ),
      _FakeAudioEngine(
        statusAfterStart: const AudioEngineStatus(
          hasPermission: true,
          isStarted: true,
        ),
      ),
      _FakeAudioEngine(
        statusAfterStart: const AudioEngineStatus(
          hasPermission: true,
          isStarted: true,
        ),
        frameToEmit: const AudioFrame(rms: 0.1, samples: [0.1]),
      ),
    ]) {
      await MicProbe.run(
        resolveEngine: () => engine,
        resolveRoute: () => _fakeRoute(AudioRoute.unknown),
        timeout: const Duration(milliseconds: 30),
      );
      expect(engine.disposed, isTrue);
    }
  });
}
