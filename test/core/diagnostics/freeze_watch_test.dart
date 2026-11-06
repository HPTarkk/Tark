import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/freeze_watch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('describeLeftover', () {
    test('names the frozen thread, how long, and where', () {
      final lines = FreezeWatch.describeLeftover(
        'thread=main frozenForMs=37250\n'
        '  at android.bluetooth.BluetoothSocket.close\n'
        '  at com.b1101.tark.bluetooth.BluetoothServerHandler.stopHosting',
      );
      expect(lines, [
        'app: previous run was frozen when it ended thread=main '
            'frozenFor=37.3s',
        'app:   at android.bluetooth.BluetoothSocket.close',
        'app:   at com.b1101.tark.bluetooth.BluetoothServerHandler.stopHosting',
      ]);
    });

    test('a frozen Dart isolate is told apart from the main thread', () {
      final lines = FreezeWatch.describeLeftover(
        'thread=dart frozenForMs=9000',
      );
      expect(lines.single, contains('thread=dart frozenFor=9.0s'));
    });

    test('a note it cannot read still says the run ended frozen', () {
      expect(
        FreezeWatch.describeLeftover('garbage').single,
        contains('thread=unknown frozenFor=?s'),
      );
      expect(FreezeWatch.describeLeftover('\n\n'), isEmpty);
    });
  });

  group('heartbeat', () {
    const channel = MethodChannel('tark/diagnostics/watchdog');
    final calls = <String>[];

    setUp(() {
      calls.clear();
      FreezeWatch.enabled = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return <String>[];
          });
    });

    tearDown(() {
      FreezeWatch.pause();
      FreezeWatch.enabled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('beats while in the foreground and goes quiet once paused', () async {
      FreezeWatch.resume();
      FreezeWatch.resume(); // idempotent: still one beat a second
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      FreezeWatch.pause();
      final atPause = calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      final beats = calls.where((c) => c == 'heartbeat').length;
      expect(beats, inInclusiveRange(2, 4));
      expect(calls.last, 'pause', reason: 'the silence is announced');
      expect(calls.length, atPause, reason: 'no beat after pausing');
    });
  });
}
