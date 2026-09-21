import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Room start uses the freshly revalidated durable Room snapshot', () async {
    final source = await File(
      'lib/app/router/room_bound_walkie_entry.dart',
    ).readAsString();

    expect(
      source,
      contains('return _verifiedLiveFor(current, linkEstablished: linkEstablished);'),
    );
    expect(
      source,
      isNot(contains('return _verifiedLiveFor(room, linkEstablished: linkEstablished);')),
    );
  });
}
