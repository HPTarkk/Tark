import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Room invite bootstrap is QR membership plus Wi-Fi only', () async {
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();
    final page = await File(
      'lib/feature/room/presentation/page/room_qr_join_page.dart',
    ).readAsString();

    expect(sheet, contains('RoomDirectJoinBundle'));
    expect(sheet, isNot(contains('RoomProximityControlChannel')));
    expect(page, contains('joinDirect('));
    expect(page, isNot(contains('RoomProximityJoinCarrier')));
    expect(page, contains('scanned?.credentials'));
  });

  test(
    'first Room scan auto-starts only through verified Room entry',
    () async {
      final page = await File(
        'lib/feature/room/presentation/page/room_qr_join_page.dart',
      ).readAsString();
      expect(page, contains('?ride=true&start=true'));
      expect(page, contains('PreLiveHotspotBootstrap().joinHost(credentials)'));
      expect(page, isNot(contains('RoomProximity')));
    },
  );
}
