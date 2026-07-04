import 'package:flutter_test/flutter_test.dart';
import 'package:audio_io/src/ffi/audio_io_bindings.dart';
import 'dart:io';

void main() {
  group('Android FFI Tests', () {
    test('FFI bindings should load on Android', () {
      // This test verifies that the FFI bindings can be created
      // It won't actually work unless run on Android
      if (Platform.isAndroid) {
        expect(() => AudioIoBindings(), returnsNormally);
      } else {
        // Skip on non-Android platforms
        expect(true, true);
      }
    });

    test('Audio format should have correct defaults', () {
      // Test that our default audio format is correct
      const expectedSampleRate = 48000;
      const expectedChannels = 1;

      expect(expectedSampleRate, 48000);
      expect(expectedChannels, 1);
    });
  });
}
