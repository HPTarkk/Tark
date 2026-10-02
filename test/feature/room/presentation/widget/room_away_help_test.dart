import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/presentation/widget/room_rejoin_help.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

void main() {
  group('what the phone that stayed offers someone who dropped out', () {
    test('sharing the connection: show the code', () {
      expect(
        resolveRoomAwayHelp(
          mode: TransferMode.hotspot,
          side: SessionRole.host,
          sharingNow: true,
          memberWasSharing: false,
        ),
        RoomAwayHelp.showCode,
      );
    });

    test('sharing, but the connection is down right now: nothing yet', () {
      expect(
        resolveRoomAwayHelp(
          mode: TransferMode.hotspot,
          side: SessionRole.host,
          sharingNow: false,
          memberWasSharing: false,
        ),
        RoomAwayHelp.none,
      );
    });

    test('the one who dropped was sharing: scan their new code', () {
      expect(
        resolveRoomAwayHelp(
          mode: TransferMode.hotspot,
          side: SessionRole.joiner,
          sharingNow: false,
          memberWasSharing: true,
        ),
        RoomAwayHelp.scanCode,
      );
    });

    test('another joiner dropped: they rejoin the sharer, not this phone', () {
      expect(
        resolveRoomAwayHelp(
          mode: TransferMode.hotspot,
          side: SessionRole.joiner,
          sharingNow: false,
          memberWasSharing: false,
        ),
        RoomAwayHelp.none,
      );
    });

    test('home Wi-Fi and Bluetooth find their own way back', () {
      for (final mode in [TransferMode.wifi, TransferMode.bluetooth]) {
        for (final side in SessionRole.values) {
          expect(
            resolveRoomAwayHelp(
              mode: mode,
              side: side,
              sharingNow: true,
              memberWasSharing: true,
            ),
            RoomAwayHelp.none,
          );
        }
      }
    });
  });
}
