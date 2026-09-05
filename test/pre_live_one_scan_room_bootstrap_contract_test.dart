import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty Room invite uses hidden one-scan hotspot bootstrap', () async {
    final lobby = await File(
      'lib/feature/room/presentation/widget/selected_room_lobby.dart',
    ).readAsString();
    final sheet = await File(
      'lib/feature/room/presentation/widget/one_scan_room_invite_sheet.dart',
    ).readAsString();
    final bootstrap = await File(
      'lib/feature/transfer/api/pre_live_hotspot_bootstrap.dart',
    ).readAsString();

    expect(lobby, contains("import 'one_scan_room_invite_sheet.dart';"));
    expect(
      lobby,
      contains('showOneScanRoomInviteSheet('),
      reason: 'The creator must not fall back to the multi-step People sheet.',
    );
    expect(lobby, contains('bootstrapHost: true'));

    final aloneBody = lobby.indexOf(
      'if (alone)\n              ..._aloneBody(s, canInvite: canInvite)',
    );
    final unlinkedBody = lobby.indexOf(
      'else if (unlinked)\n              ..._unlinkedBody',
    );
    expect(aloneBody, greaterThanOrEqualTo(0));
    expect(unlinkedBody, greaterThan(aloneBody));

    final bootstrapCall = sheet.indexOf('.prepareHost()');
    final inviteWrite = sheet.indexOf(
      'final invite = await _repository.issueInvite(',
    );
    expect(bootstrapCall, greaterThanOrEqualTo(0));
    expect(inviteWrite, greaterThan(bootstrapCall));
    expect(
      sheet,
      contains('credentials.qrPayload(roomInvite: roomInvite)'),
      reason: 'The primary QR must carry both membership and the hotspot.',
    );

    expect(
      bootstrap,
      contains('if (roleStore.role != SessionRole.host) return null;'),
      reason: 'Room invite authority must never elect the hotspot host.',
    );
    expect(bootstrap, contains('await bridge.chooseRole(HotspotRole.host);'));
    expect(
      bootstrap,
      contains('await bridge.close();'),
      reason:
          'The hidden bridge must hand the established attachment to the '
          'HotspotLinkKeeper instead of leaving setup subscriptions alive.',
    );
  });
}
