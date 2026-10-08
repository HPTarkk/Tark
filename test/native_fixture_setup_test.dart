import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quality gate requires every actual native fixture', () {
    for (final variable in [
      'AUDIO_IO_TEST_LIBRARY',
      'AUDIO_IO_TEST_INCOMPLETE_LIBRARY',
      'RNNOISE_LIBRARY_PATH',
      'RNNOISE_LEGACY_LIBRARY_PATH',
    ]) {
      final path = Platform.environment[variable];
      expect(path, isNotNull, reason: '$variable must be built before testing');
      expect(File(path!).existsSync(), isTrue, reason: '$variable: $path');
    }
  }, skip: Platform.environment['TARK_REQUIRE_NATIVE_TESTS'] != '1');
}
