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
      expect(
        sheet,
        contains('currentHotspotCredentials: _currentLiveHotspotCredentials'),
      );
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
      final entry = await File(
        'lib/app/router/room_bound_walkie_entry.dart',
      ).readAsString();
      final bootstrap = await File(
        'lib/feature/transfer/api/pre_live_hotspot_bootstrap.dart',
      ).readAsString();

      expect(lobby, contains('_startRide()'));
      // The lobby hands Start to the entry, and only the entry decides — from
      // which end of the proximity hand-off this phone is — whether it raises
      // the hotspot. A second decision in the lobby is how the creator used to
      // raise one while somebody else was doing the inviting.
      expect(lobby, isNot(contains('PreLiveHotspotBootstrap')));
      expect(entry, contains('PreLiveHotspotBootstrap().prepareHost()'));
      expect(sheet, isNot(contains('PreLiveHotspotBootstrap()')));
      expect(
        bootstrap,
        contains('unawaited(_releaseBridgeAfterHandoff(bridge));'),
      );
      expect(
        bootstrap.indexOf('unawaited(_releaseBridgeAfterHandoff(bridge));'),
        lessThan(bootstrap.indexOf('return credentials;')),
      );
    },
  );
}
