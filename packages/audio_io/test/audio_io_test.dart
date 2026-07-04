import 'package:flutter_test/flutter_test.dart';
import 'package:audio_io/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AudioIo.instance.start();
  });

  tearDown(() {
    AudioIo.instance.stop();
  });
}
