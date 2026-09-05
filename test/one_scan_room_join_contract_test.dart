import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Room QR join persists membership before spending network payload', () async {
    final source = await File(
      'lib/feature/room/presentation/page/room_qr_join_page.dart',
    ).readAsString();

    final parse = source.indexOf('final scanned = ScannedCode.parse(raw);');
    final room = source.indexOf('final roomRaw = scanned?.roomInvite ?? raw;');
    final persist = source.indexOf('await widget.cubit.joinDirect(');
    final route = source.indexOf(
      'context.go(ConnectRoute.forScannedNetwork(), extra: raw);',
    );

    expect(parse, greaterThanOrEqualTo(0));
    expect(room, greaterThan(parse));
    expect(persist, greaterThan(room));
    expect(route, greaterThan(persist));
    expect(
      source,
      contains('if (scanned?.credentials != null)'),
      reason: 'Transport bootstrap must only consume the same scan after the '
          'Room join has been accepted and persisted.',
    );
  });

  test('active Room Add person opens exactly the one-scan invite surface', () async {
    final action = await File(
      'lib/feature/room/presentation/widget/in_room_people_action.dart',
    ).readAsString();
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();

    expect(action, contains('showOneScanRoomInviteSheet('));
    expect(action, isNot(contains('showRoomPeopleSheet(')));
    expect(RegExp(r'GlowingQrCard\(').allMatches(sheet), hasLength(1));
    expect(sheet, contains('credentials.qrPayload(roomInvite: roomInvite)'));
    expect(sheet, isNot(contains('people_wifi_title')));
    expect(sheet, isNot(contains('room-invite-wifi-qr')));
    expect(sheet, isNot(contains('room-invite-display-code')));
  });
}
