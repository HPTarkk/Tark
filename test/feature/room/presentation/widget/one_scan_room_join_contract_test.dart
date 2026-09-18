import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Room QR is bootstrap only and cannot finalize membership directly',
    () async {
      final source = await File(
        'lib/feature/room/presentation/page/room_qr_join_page.dart',
      ).readAsString();

      expect(source, contains('RoomInvitation.decode(raw)'));
      expect(
        source,
        contains('control.connect(rendezvousToken: invitation.invitationId)'),
      );
      expect(source, contains('RoomProximityJoinCarrier('));
      expect(source, contains('widget.cubit.joinByInvite('));
      expect(source, isNot(contains('joinDirect(')));
      expect(source, isNot(contains('RoomDirectJoinBundle.decode')));
      expect(
        source,
        contains('if (_joining) return false;'),
        reason:
            'duplicate camera frames must not create duplicate join requests',
      );
    },
  );

  test('active Room Add person exposes one stable rendezvous QR', () async {
    final action = await File(
      'lib/feature/room/presentation/widget/in_room_people_action.dart',
    ).readAsString();
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();

    expect(action, contains('showOneScanRoomInviteSheet('));
    expect(RegExp(r'GlowingQrCard\(').allMatches(sheet), hasLength(1));
    expect(sheet, contains('_roomInvite = invite.encode();'));
    expect(sheet, contains('requireMembershipReceipt: true'));
    expect(sheet, contains('RoomProximityJoinIssuerSession('));
    expect(
      sheet,
      contains('_control.host(rendezvousToken: invite.invitationId)'),
    );
    expect(sheet, isNot(contains('credentials.qrPayload')));
    expect(sheet, isNot(contains('RoomDirectJoinBundle')));
    expect(sheet, isNot(contains('.prepareHost()')));
  });

  test('the channel recovery banner mints the same one-scan invite', () async {
    final recovery = await File(
      'lib/feature/walkie/presentation/widget/channel_recovery.dart',
    ).readAsString();

    // The legacy people sheet mints `tark-room:` codes, which the scanner
    // refuses as invalid. No in-channel surface may hand one out.
    expect(recovery, contains('showOneScanRoomInviteSheet('));
    expect(recovery, isNot(contains('showRoomPeopleSheet(')));
  });

  test('issuer listener exists before the QR can be scanned', () async {
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();
    final listener = sheet.indexOf(
      'final issuerSession = RoomProximityJoinIssuerSession(',
    );
    final retained = sheet.indexOf('_issuerSession = issuerSession;');
    final releasePrevious = sheet.indexOf(
      'await RoomProximityControlSessionRegistry.instance.clear(',
    );
    final host = sheet.indexOf('await _control.host(');
    final qr = sheet.indexOf('_roomInvite = invite.encode();');

    expect(listener, greaterThanOrEqualTo(0));
    expect(retained, greaterThan(listener));
    expect(releasePrevious, greaterThan(retained));
    expect(host, greaterThan(releasePrevious));
    expect(qr, greaterThan(host));
  });
}
