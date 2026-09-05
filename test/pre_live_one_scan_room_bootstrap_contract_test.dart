import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Room invite and Start keep hotspot bootstrap hidden', () async {
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
    expect(lobby, contains('showOneScanRoomInviteSheet('));
    expect(
      lobby,
      contains(
        'bootstrapHost: !_hasReusableRoomHotspot && _isPreferredBootstrapHost',
      ),
      reason:
          'Only the deterministic preferred bootstrap side may raise a new '
          'hotspot for a one-scan invite.',
    );
    expect(
      lobby,
      contains('(widget.preLiveBootstrap ?? PreLiveHotspotBootstrap())'),
      reason:
          'Start must use the same hidden transfer bridge rather than exposing '
          'Host / Join setup in the Room UI.',
    );
    expect(lobby, contains('.prepareHost();'));

    final bootstrapCall = sheet.indexOf('.prepareHost()');
    final inviteWrite = sheet.indexOf(
      'final invite = await _repository.issueInvite(',
    );
    expect(bootstrapCall, greaterThanOrEqualTo(0));
    expect(inviteWrite, greaterThan(bootstrapCall));
    expect(
      sheet,
      contains('credentials.qrPayload(roomInvite: roomInvite)'),
      reason: 'The primary QR must carry membership and fallback carrier.',
    );

    expect(
      bootstrap,
      contains('if (roleStore.role != SessionRole.host) return null;'),
      reason:
          'Invite permission alone must never elect a hotspot host; the hidden '
          'bridge still requires the session-scoped bootstrap host hint.',
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
