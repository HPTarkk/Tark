import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cold first invite is independent from hotspot bootstrap', () async {
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();

    final listener = sheet.indexOf(
      'final issuerSession = RoomProximityJoinIssuerSession(',
    );
    final retained = sheet.indexOf('_issuerSession = issuerSession;');
    final proximityReady = sheet.indexOf('await _control.host(');
    final qrReady = sheet.indexOf('_roomInvite = invite.encode();');

    expect(listener, greaterThanOrEqualTo(0));
    expect(retained, greaterThan(listener));
    expect(proximityReady, greaterThan(retained));
    expect(qrReady, greaterThan(proximityReady));

    // The membership QR is now a stable rendezvous token. LocalOnlyHotspot is
    // a later transport-plane concern and must not delay or mutate this QR.
    expect(sheet, isNot(contains('.prepareHost()')));
    expect(sheet, isNot(contains('credentials.qrPayload')));
    expect(sheet, isNot(contains('RoomDirectJoinBundle')));
  });

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
