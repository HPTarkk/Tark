import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Room invite bootstrap is proximity-only and transport-neutral',
    () async {
      final sheet = await File(
        'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
      ).readAsString();
      final page = await File(
        'lib/feature/room/presentation/page/room_qr_join_page.dart',
      ).readAsString();

      expect(sheet, contains('RoomProximityControlChannel'));
      expect(sheet, contains('RoomProximityJoinIssuerSession'));
      expect(sheet, contains('_roomInvite = invite.encode();'));
      expect(sheet, isNot(contains('.prepareHost()')));
      expect(sheet, isNot(contains('HotspotCredentials')));
      expect(sheet, isNot(contains('qrPayload(roomInvite:')));

      expect(page, contains('RoomProximityJoinCarrier'));
      expect(page, contains('joinByInvite('));
      expect(page, isNot(contains('joinDirect(')));
      expect(page, isNot(contains('scanned?.credentials')));
    },
  );

  test(
    'Start may plan transport only outside the membership QR surface',
    () async {
      final lobby = await File(
        'lib/feature/room/presentation/widget/selected_room_lobby.dart',
      ).readAsString();
      final sheet = await File(
        'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
      ).readAsString();

      expect(lobby, contains('_startRide()'));
      expect(lobby, contains('PreLiveHotspotBootstrap'));
      expect(sheet, isNot(contains('PreLiveHotspotBootstrap()')));
    },
  );
}
