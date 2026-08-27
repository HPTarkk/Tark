import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/presentation/manager/room_qr_join_carrier.dart';

void main() {
  test('exchange publishes request and completes only from scanned response', () async {
    final carrier = RoomQrJoinCarrier();
    addTearDown(carrier.dispose);
    final requestSeen = Completer<String>();
    final subscription = carrier.requests.listen(requestSeen.complete);
    addTearDown(subscription.cancel);

    final exchange = carrier.exchange('request-a');

    expect(await requestSeen.future, 'request-a');
    expect(carrier.awaitingResponse, isTrue);
    expect(carrier.submitResponse('response-a'), isTrue);
    expect(await exchange, 'response-a');
    expect(carrier.awaitingResponse, isFalse);
  });

  test('duplicate scanner frame cannot complete a later attempt', () async {
    final carrier = RoomQrJoinCarrier();
    addTearDown(carrier.dispose);

    final first = carrier.exchange('request-a');
    expect(carrier.submitResponse('response-a'), isTrue);
    expect(carrier.submitResponse('duplicate-a'), isFalse);
    expect(await first, 'response-a');

    final second = carrier.exchange('request-b');
    expect(carrier.submitResponse('response-b'), isTrue);
    expect(await second, 'response-b');
  });

  test('concurrent exchanges fail closed', () async {
    final carrier = RoomQrJoinCarrier();
    addTearDown(carrier.dispose);

    final first = carrier.exchange('request-a');
    expect(() => carrier.exchange('request-b'), throwsStateError);
    carrier.submitResponse('response-a');
    expect(await first, 'response-a');
  });

  test('cancel rejects the active exchange without leaving stale state', () async {
    final carrier = RoomQrJoinCarrier();
    addTearDown(carrier.dispose);

    final exchange = carrier.exchange('request-a');
    carrier.cancel();

    await expectLater(exchange, throwsStateError);
    expect(carrier.awaitingResponse, isFalse);
  });
}
