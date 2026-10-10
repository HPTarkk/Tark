import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Room QR imports the signed direct bundle; the radio only reaches the host',
    () async {
      final source = await File(
        'lib/feature/room/presentation/page/room_qr_join_page.dart',
      ).readAsString();
      expect(source, contains('RoomDirectJoinBundle.decode'));
      expect(source, contains('widget.cubit.joinDirect('));
      // Membership never rides on Bluetooth: it is saved from the QR first,
      // and only a Bluetooth Room then uses the radio to reach the host.
      expect(source, isNot(contains('RoomProximity')));
      final join = source.indexOf('widget.cubit.joinDirect(');
      final bluetooth = source.indexOf('_joinOverBluetooth(bluetooth.link)');
      expect(bluetooth, greaterThan(join));
    },
  );

  test('Add person mints one signed direct Room QR', () async {
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();
    expect('GlowingQrCard('.allMatches(sheet), hasLength(1));
    expect(sheet, contains('RoomDirectJoinBundle('));
    expect(sheet, contains('_roomInvite = bundle.encode();'));
    expect(sheet, isNot(contains('RoomProximity')));
    expect(sheet, isNot(contains('ensureRoomInviteBluetoothPermissions')));
  });
}
