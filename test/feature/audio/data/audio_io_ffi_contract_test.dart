import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/audio_io_native.dart';
import 'package:audio_io/src/ffi/audio_io_bindings.dart';
import 'package:audio_io/src/ffi/audio_io_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('older native libraries leave optional DSP unavailable', () {
    final bindings = AudioIoBindings.realtimeDsp(DynamicLibrary.process());
    expect(bindings.hasResampler, isFalse);
    expect(bindings.hasLowPass, isFalse);
    expect(bindings.hasSpectralSuppressor, isFalse);
    final platform = AudioIoNative(realtimeBindings: bindings);
    expect(platform.createRealtimeResampler(48000, 16000), isNull);
    expect(platform.createRealtimeLowPass(48000, 7200), isNull);
    expect(platform.createRealtimeSpectralSuppressor(16000), isNull);
    expect(
      () => FfiRealtimeResampler.create(bindings, 48000, 16000),
      throwsUnsupportedError,
    );
    expect(
      () => FfiRealtimeLowPass.create(bindings, 48000, 7200),
      throwsUnsupportedError,
    );
    expect(
      () => FfiRealtimeSpectralSuppressor.create(bindings, 16000),
      throwsUnsupportedError,
    );
  });

  final incompletePath =
      Platform.environment['AUDIO_IO_TEST_INCOMPLETE_LIBRARY'];
  test('a partial spectral ABI keeps other DSP groups usable', () {
    final bindings = AudioIoBindings.realtimeDsp(
      DynamicLibrary.open(incompletePath!),
    );
    expect(bindings.hasResampler, isTrue);
    expect(bindings.hasLowPass, isTrue);
    expect(bindings.hasSpectralSuppressor, isFalse);
    expect(bindings.spectralCreate, isNull);
    expect(bindings.spectralProcess, isNull);
    expect(bindings.spectralDestroy, isNull);
    final platform = AudioIoNative(realtimeBindings: bindings);
    expect(platform.createRealtimeSpectralSuppressor(16000), isNull);
    final resampler = FfiRealtimeResampler.create(bindings, 48000, 16000);
    final lowPass = FfiRealtimeLowPass.create(bindings, 48000, 7200);
    try {
      expect(resampler.process([0.1, 0.2, 0.3, 0.4]), isNotEmpty);
      expect(lowPass.process([0.1, 0.2]), hasLength(2));
    } finally {
      resampler.dispose();
      lowPass.dispose();
    }
  }, skip: incompletePath == null ? 'Native ABI fixture is not built' : false);

  final libraryPath = Platform.environment['AUDIO_IO_TEST_LIBRARY'];
  group('production realtime DSP FFI ABI', () {
    late AudioIoBindings bindings;
    late int Function() liveHandles;
    late int initialHandles;

    setUp(() {
      final library = DynamicLibrary.open(libraryPath!);
      bindings = AudioIoBindings.realtimeDsp(library);
      liveHandles = library.lookupFunction<Int32 Function(), int Function()>(
        'audio_io_test_live_handles',
      );
      initialHandles = liveHandles();
    });
    tearDown(
      () => expect(
        liveHandles(),
        initialHandles,
        reason: 'Every native DSP handle must be released',
      ),
    );

    test('facade exposes every DSP interface and native capability', () {
      expect(bindings.hasResampler, isTrue);
      expect(bindings.hasLowPass, isTrue);
      expect(bindings.hasSpectralSuppressor, isTrue);
      final RealtimeResampler resampler = FfiRealtimeResampler.create(
        bindings,
        48000,
        16000,
      );
      final RealtimeLowPass lowPass = FfiRealtimeLowPass.create(
        bindings,
        48000,
        7200,
      );
      final RealtimeSpectralSuppressor spectral =
          FfiRealtimeSpectralSuppressor.create(bindings, 16000);
      expect(liveHandles(), initialHandles + 3);
      resampler.dispose();
      lowPass.dispose();
      spectral.dispose();
      resampler.dispose();
      lowPass.dispose();
      spectral.dispose();
    });

    test('one-sample callbacks retain their input when capacity is zero', () {
      final resampler = FfiRealtimeResampler.create(bindings, 16000, 16000);
      try {
        expect(resampler.process([0.25]), isEmpty);
        expect(resampler.process([-0.3]), orderedEquals([0.25]));
        expect(resampler.process([0.8]), orderedEquals([-0.3]));
        resampler.reset();
        expect(resampler.process([0.9, 0.4]), orderedEquals([0.9]));
      } finally {
        resampler.dispose();
      }
    });

    test('disposed processors fail before accepting even empty callbacks', () {
      final resampler = FfiRealtimeResampler.create(bindings, 48000, 16000);
      final lowPass = FfiRealtimeLowPass.create(bindings, 48000, 7200);
      final spectral = FfiRealtimeSpectralSuppressor.create(bindings, 16000);
      // Exercise scratch growth and both ordinary and typed input copies.
      for (final frames in [1, 320, 7, 4096]) {
        final input = Float64List(frames);
        resampler.process(input);
        lowPass.process(input.toList());
        spectral.process(input);
      }
      resampler.dispose();
      lowPass.dispose();
      spectral.dispose();
      for (final samples in <List<double>>[
        [],
        [0.1],
      ]) {
        expect(() => resampler.process(samples), throwsStateError);
        expect(() => lowPass.process(samples), throwsStateError);
        expect(() => spectral.process(samples), throwsStateError);
      }
      expect(resampler.reset, throwsStateError);
      expect(lowPass.reset, throwsStateError);
      expect(spectral.reset, throwsStateError);
      expect(() => spectral.strength = 0.5, throwsStateError);
    });

    test('invalid parameters never allocate native state', () {
      for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => FfiRealtimeResampler.create(bindings, invalid, 16000),
          throwsArgumentError,
        );
        expect(
          () => FfiRealtimeResampler.create(bindings, 48000, invalid),
          throwsArgumentError,
        );
        expect(
          () => FfiRealtimeLowPass.create(bindings, invalid, 7200),
          throwsArgumentError,
        );
        expect(
          () => FfiRealtimeLowPass.create(bindings, 48000, invalid),
          throwsArgumentError,
        );
      }
      expect(
        () => FfiRealtimeSpectralSuppressor.create(bindings, 0),
        throwsArgumentError,
      );
      final spectral = FfiRealtimeSpectralSuppressor.create(bindings, 24000);
      try {
        spectral.strength = -2;
        expect(spectral.strength, 0);
        spectral.strength = 2;
        expect(spectral.strength, 1);
        expect(() => spectral.strength = double.nan, throwsArgumentError);
        expect(() => spectral.strength = double.infinity, throwsArgumentError);
        expect(spectral.strength, 1);
      } finally {
        spectral.dispose();
      }
    });

    test('native allocation errors surface without consuming the input', () {
      final library = DynamicLibrary.open(libraryPath!);
      final failNextAllocation = library
          .lookupFunction<Void Function(), void Function()>(
            'audio_io_test_fail_next_allocation',
          );
      final resampler = FfiRealtimeResampler.create(bindings, 16000, 16000);
      try {
        failNextAllocation();
        expect(() => resampler.process([0.3, -0.5]), throwsStateError);
        expect(resampler.process([0.3, -0.5]), orderedEquals([0.3]));
      } finally {
        resampler.dispose();
      }
    });
  }, skip: libraryPath == null ? 'Native ABI fixture is not built' : false);
}
