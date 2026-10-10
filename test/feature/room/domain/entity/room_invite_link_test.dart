import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_invite_link.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';

void main() {
  const invite = 'tark-room:AbC_d-12';

  group('BluetoothInviteLink', () {
    test('round-trips its token and the Room invite through one code', () {
      final link = BluetoothInviteLink.fresh(Random(7));
      final parsed = BluetoothInviteLink.tryParse(link.payload(invite));

      expect(parsed, isNotNull);
      expect(parsed!.link.token, link.token);
      expect(parsed.roomInvite, invite);
    });

    test('a fresh token is 16 random bytes, different every invite', () {
      final a = BluetoothInviteLink.fresh();
      final b = BluetoothInviteLink.fresh();
      expect(a.token, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a.token, isNot(b.token));
    });

    test('anything else is not a Bluetooth invite', () {
      expect(BluetoothInviteLink.tryParse(invite), isNull);
      expect(BluetoothInviteLink.tryParse('WIFI:S:x;P:y;;'), isNull);
      expect(BluetoothInviteLink.tryParse('tark-bt1:short:$invite'), isNull);
      expect(BluetoothInviteLink.tryParse('tark-bt1:${'a' * 32}:'), isNull);
    });
  });

  test('HotspotInviteLink stays one standard Wi-Fi code carrying the Room', () {
    const creds = HotspotCredentials(ssid: 'AndroidShare_1', passphrase: 'pw');
    final scanned = ScannedCode.parse(
      const HotspotInviteLink(creds).payload(invite),
    );
    expect(scanned?.credentials, creds);
    expect(scanned?.roomInvite, invite);
  });
}
