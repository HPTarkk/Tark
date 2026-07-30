import '../entity/bluetooth_peer.dart';

/// Whether a discovered device belongs in the joiner's list at all.
///
/// A classic inquiry reports everything in radio range — headsets, TVs,
/// laptops, somebody's car — and none of it can be joined. Only a device
/// hosting from inside the app can, and the broadcast-name tag
/// (bluetooth_host_name.dart) is what identifies one, so everything else is
/// dropped rather than merely sorted last: the list then shows people instead
/// of hardware. BLE peers arrive already filtered on the Tark service UUID, so
/// this only ever bites the classic side.
///
/// [reconnectTargetId] is the peer a targeted rescan is chasing, if any. That
/// address was a Tark host the last time the two linked, and Android can still
/// be reporting a stale cached adapter name for it, so filtering it out would
/// strand the auto-reconnect — it is let through on its id alone.
bool isVisibleHost(BluetoothPeer peer, {String? reconnectTargetId}) =>
    peer.isAppHost || peer.id == reconnectTargetId;
