import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cold first invite is direct membership before hotspot bootstrap',
    () async {
      final sheet = await File(
        'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
      ).readAsString();

      final bundle = sheet.indexOf('final bundle = RoomDirectJoinBundle(');
      final encoded = sheet.indexOf('_roomInvite = bundle.encode();');
      // The network half (hotspot or Bluetooth) only wraps the
      // already-issued membership.
      final credentials = sheet.indexOf('link.payload(roomInvite)');

      expect(bundle, greaterThanOrEqualTo(0));
      expect(encoded, greaterThan(bundle));
      expect(credentials, greaterThan(encoded));

      // Membership is self-contained in the signed QR. Bluetooth/proximity is
      // not allowed back into Room bootstrap, and hotspot credentials only wrap
      // the already-issued membership when this phone is currently the host.
      expect(sheet, contains('RoomDirectJoinBundle'));
      expect(sheet, isNot(contains('RoomProximityJoinIssuerSession')));
      expect(sheet, isNot(contains('RoomProximityControl')));
      expect(sheet, isNot(contains('.prepareHost()')));
    },
  );

  test(
    'startup composition bypasses ConsentGate but keeps legal code',
    () async {
      final app = await File('lib/app/my_app.dart').readAsString();
      final gate = File(
        'lib/feature/legal/presentation/widget/consent_gate.dart',
      );

      expect(
        app,
        isNot(contains("feature/legal/presentation/widget/consent_gate.dart")),
      );
      expect(app, isNot(contains('ConsentGate(child: child!)')));
      expect(app, contains('child: child!'));
      expect(await gate.exists(), isTrue);
    },
  );
}
