import 'package:get_it/get_it.dart';

import '../../../core/utils/logger.dart';
import '../../transfer/api/transfer_api.dart';
import '../domain/entity/room_invite_link.dart';
import 'room_bluetooth_permissions.dart';

/// How reaching the host of a Bluetooth invite ended.
enum BluetoothInviteJoinResult {
  joined,
  permissionDenied,
  locationOff,
  bluetoothOff,
  notFound,
}

/// The scanning side of a one-scan invite over Bluetooth: find the phone
/// advertising the invite's token, dial it once so it knows this phone has
/// arrived, then open the audio link to the address that answered.
///
/// `BluetoothInviteHost` is the other side.
class BluetoothInviteJoiner {
  BluetoothInviteJoiner({
    RoomProximityControlChannel Function()? control,
    BluetoothTransport? transport,
    Future<bool> Function()? permissions,
    Future<bool> Function()? locationReady,
  }) : _control = control ?? RoomProximityControlChannel.new,
       _transport = transport,
       _permissions = permissions ?? ensureRoomInviteBluetoothPermissions,
       _locationReady = locationReady ?? roomScanLocationReady;

  final RoomProximityControlChannel Function() _control;
  final BluetoothTransport? _transport;
  final Future<bool> Function() _permissions;
  final Future<bool> Function() _locationReady;

  Future<BluetoothInviteJoinResult> join(BluetoothInviteLink link) async {
    try {
      if (!await _permissions()) {
        return BluetoothInviteJoinResult.permissionDenied;
      }
      if (!await _locationReady()) return BluetoothInviteJoinResult.locationOff;
    } catch (error) {
      Logger.diagnostic('room_join: bluetooth permission ${error.runtimeType}');
      return BluetoothInviteJoinResult.permissionDenied;
    }

    final control = _control();
    String? address;
    try {
      await control.connect(rendezvousToken: link.token);
      address = control.peerAddress;
    } on RoomProximityException catch (error) {
      Logger.diagnostic('room_join: bluetooth find ${error.failure.name}');
      return error.failure == RoomProximityFailure.bluetoothOff
          ? BluetoothInviteJoinResult.bluetoothOff
          : BluetoothInviteJoinResult.notFound;
    } catch (error) {
      Logger.diagnostic('room_join: bluetooth find ${error.runtimeType}');
      return BluetoothInviteJoinResult.notFound;
    } finally {
      // One Bluetooth socket at a time: the finding socket has to go before
      // the audio link can dial.
      await control.dispose();
    }

    final transport =
        _transport ??
        (GetIt.instance.isRegistered<BluetoothTransport>()
            ? GetIt.instance<BluetoothTransport>()
            : null);
    if (address == null || transport == null) {
      return BluetoothInviteJoinResult.notFound;
    }
    if (GetIt.instance.isRegistered<TransferModeStore>()) {
      // The code is the host's choice of connection, so this Room follows it
      // here too; otherwise a Wi-Fi preference on this phone would refuse the
      // very link it is about to open.
      final modes = GetIt.instance<TransferModeStore>();
      await modes.setPinnedMode(TransferMode.bluetooth);
      await modes.setMode(TransferMode.bluetooth);
    }
    final linked = await BluetoothLinkHandoff(transport).join(address);
    return linked
        ? BluetoothInviteJoinResult.joined
        : BluetoothInviteJoinResult.notFound;
  }
}
