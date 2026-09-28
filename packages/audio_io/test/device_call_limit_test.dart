import 'dart:async';

import 'package:audio_io/src/device_call_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const limit = Duration(milliseconds: 20);

  test('a call that returns in time passes its result through', () async {
    final result = await limitDeviceCall(
      Future.value(7),
      limit: limit,
      onTimeout: () => 0,
    );
    expect(result, 7);
  });

  test('a call that never returns is abandoned after the limit', () async {
    var timedOut = false;
    final result = await limitDeviceCall(
      Completer<int>().future,
      limit: limit,
      onTimeout: () {
        timedOut = true;
        return 0;
      },
    );
    expect(result, 0);
    expect(timedOut, isTrue);
  });

  test('a result that lands after the limit goes to onLate', () async {
    final call = Completer<int>();
    int? late;
    final result = await limitDeviceCall(
      call.future,
      limit: limit,
      onTimeout: () => 0,
      onLate: (value) => late = value,
    );
    expect(result, 0);
    expect(late, isNull);

    call.complete(42);
    await Future<void>.delayed(Duration.zero);
    expect(late, 42);
  });

  test('a result in time never reaches onLate', () async {
    int? late;
    await limitDeviceCall(
      Future.value(5),
      limit: limit,
      onTimeout: () => 0,
      onLate: (value) => late = value,
    );
    await Future<void>.delayed(limit * 2);
    expect(late, isNull);
  });

  test('an error in time is passed through', () async {
    await expectLater(
      limitDeviceCall<int>(
        Future.error(StateError('boom')),
        limit: limit,
        onTimeout: () => 0,
      ),
      throwsStateError,
    );
  });

  test('diagnostics go to the sink the app plugged in', () {
    final lines = <String>[];
    AudioIoDiagnostics.sink = lines.add;
    addTearDown(() => AudioIoDiagnostics.sink = null);
    AudioIoDiagnostics.report('hello');
    expect(lines, ['hello']);
  });
}
