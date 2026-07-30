import '../entity/bluetooth_host_name.dart';
import '../entity/bluetooth_peer.dart';

/// Collapses the several radio "faces" of one phone into a single peer.
///
/// An Android host advertises over Classic *and* BLE at the same time, so a
/// scanning joiner meets the same friend twice. Besides reading as two people
/// in the list, the duplicate defeated the hands-free solo join: that
/// deliberately refuses to guess whenever two hosts are in range, so a single
/// host showing up twice was never joined automatically.
///
/// Only app hosts are merged — the headsets, TVs and laptops a classic
/// inquiry sweeps up are passed through untouched.
List<BluetoothPeer> mergeHostFaces(List<BluetoothPeer> peers) {
  final hosts = peers.where((p) => p.isAppHost).toList();
  final others = peers.where((p) => !p.isAppHost).toList();
  if (hosts.length < 2) return peers;

  final merged = <BluetoothPeer>[];
  final claimed = <int>{};
  for (var i = 0; i < hosts.length; i++) {
    if (claimed.contains(i)) continue;
    var face = hosts[i];
    for (var j = i + 1; j < hosts.length; j++) {
      if (claimed.contains(j) || !_isSameDevice(face, hosts[j], hosts)) {
        continue;
      }
      claimed.add(j);
      face = _combine(face, hosts[j]);
    }
    merged.add(face);
  }
  // Callers sort the list themselves (app hosts first, then signal), so the
  // order here only has to be stable, not final.
  return [...merged, ...others];
}

/// Whether two host entries are the same phone seen over different radios.
/// Never merges two entries from the *same* radio: those really are two
/// devices.
bool _isSameDevice(
  BluetoothPeer a,
  BluetoothPeer b,
  List<BluetoothPeer> allHosts,
) {
  if (a.isBle == b.isBle) return false;

  // Exact when it applies: on Android a BLE peer's id is built from its MAC
  // (00000000-0000-0000-0000-<mac>), which is the same address the classic
  // inquiry reported. A mismatch proves nothing though — Android may advertise
  // from a rotating private address — so fall through rather than rule it out.
  final macA = _macOf(a);
  final macB = _macOf(b);
  if (macA != null && macB != null && macA == macB) return true;

  if (!_isAnonymous(a) && !_isAnonymous(b)) {
    final nameA = a.name.trim().toLowerCase();
    final nameB = b.name.trim().toLowerCase();
    return nameA.isNotEmpty && nameA == nameB;
  }

  // One side advertised no name and no usable address, so nothing identifies
  // it directly. Claim it only when the situation is unambiguous: exactly one
  // classic host and exactly one anonymous BLE host in range. Every Android
  // host advertises on both radios, so a second phone would have brought its
  // own classic entry along — and an iPhone (BLE only) would leave the classic
  // count at zero.
  final classicHosts = allHosts.where((p) => !p.isBle).length;
  final anonymousBle = allHosts.where((p) => p.isBle && _isAnonymous(p)).length;
  final namedBle = allHosts.where((p) => p.isBle && !_isAnonymous(p)).length;
  return classicHosts == 1 && anonymousBle == 1 && namedBle == 0;
}

/// Keeps the classic id (on Android the higher-bandwidth link, and the one two
/// Android phones can always use), the more informative name, and the stronger
/// of the two signal readings.
BluetoothPeer _combine(BluetoothPeer a, BluetoothPeer b) {
  final primary = a.isBle ? b : a;
  final secondary = identical(primary, a) ? b : a;
  final name = _isAnonymous(primary) && !_isAnonymous(secondary)
      ? secondary.name
      : primary.name;
  final rssiA = primary.rssi;
  final rssiB = secondary.rssi;
  final rssi = rssiA == null
      ? rssiB
      : rssiB == null
      ? rssiA
      : (rssiA > rssiB ? rssiA : rssiB);
  return BluetoothPeer(
    id: primary.id,
    name: name,
    rssi: rssi,
    isAppHost: true,
  );
}

/// A host whose advertisement carried no name (see [kMaxHostNameBytes]) —
/// nothing about it identifies which phone it is.
bool _isAnonymous(BluetoothPeer peer) => peer.name.trim().isEmpty;

/// The 12 hex digits of the peer's Bluetooth address, or null when the id
/// carries no address — an iOS peripheral identifier is a random UUID, and
/// iOS has no classic engine to duplicate against anyway.
String? _macOf(BluetoothPeer peer) {
  const androidBlePrefix = '00000000-0000-0000-0000-';
  final raw = peer.isBle ? peer.id.substring(4) : peer.id;
  if (peer.isBle && !raw.startsWith(androidBlePrefix)) return null;
  final hex = raw.replaceAll(RegExp('[^0-9a-fA-F]'), '').toLowerCase();
  if (hex.length < 12) return null;
  return hex.substring(hex.length - 12);
}
